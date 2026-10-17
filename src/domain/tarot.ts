import {createHmac, randomUUID} from 'node:crypto';

export const TAROT_ALGORITHM = 'fj-tarot-major-v1';
// Original non-proprietary card names; no copyrighted deck art or passages.
export const MAJOR_ARCANA = [
  'The Fool',
  'The Magician',
  'The High Priestess',
  'The Empress',
  'The Emperor',
  'The Hierophant',
  'The Lovers',
  'The Chariot',
  'Strength',
  'The Hermit',
  'Wheel of Fortune',
  'Justice',
  'The Hanged Man',
  'Death',
  'Temperance',
  'The Devil',
  'The Tower',
  'The Star',
  'The Moon',
  'The Sun',
  'Judgement',
  'The World',
] as const;
export type TarotCard = {index: number; name: string; orientation: 'upright' | 'reversed'};

/** A caller can reuse drawId for reproducible results. No birth or question text is persisted. */
export function drawTarot(
  userId: string,
  signingSecret: string,
  count: 1 | 3,
  drawId: string = randomUUID(),
): {schemaVersion: '1.0'; algorithm: string; drawId: string; cards: TarotCard[]; disclaimer: string} {
  if (count !== 1 && count !== 3) throw new Error('INVALID_COUNT');
  if (!signingSecret || signingSecret.length < 24) throw new Error('MISSING_SECRET');
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(drawId))
    throw new Error('INVALID_DRAW_ID');
  const remaining: number[] = MAJOR_ARCANA.map((_, i) => i);
  const cards: TarotCard[] = [];
  for (let i = 0; i < count; i++) {
    const hmac = createHmac('sha256', signingSecret)
      .update(`${TAROT_ALGORITHM}:${userId}:${drawId}:${i}`)
      .digest();
    const idx = hmac.readUInt32BE(0) % remaining.length;
    const cardIndex = remaining.splice(idx, 1)[0];
    cards.push({
      index: cardIndex,
      name: MAJOR_ARCANA[cardIndex],
      orientation: hmac.readUInt8(4) % 2 === 0 ? 'upright' : 'reversed',
    });
  }
  return {
    schemaVersion: '1.0',
    algorithm: TAROT_ALGORITHM,
    drawId,
    cards,
    disclaimer: 'Tarot is a symbolic reflection tool, not evidence about the future or other people.',
  };
}
