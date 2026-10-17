/** Stable, explicitly versioned numerology convention. This is entertainment, not prediction. */
export const NUMEROLOGY_ALGORITHM = 'fj-numerology-v1';

export type NumerologyReading = {
  schemaVersion: '1.0';
  algorithm: typeof NUMEROLOGY_ALGORITHM;
  birthDate: string;
  asOf: string;
  lifePath: number;
  personalYear: number;
  personalMonth: number;
  interpretationKeys: string[];
  disclaimer: string;
};

export function parseISODate(value: string): {year: number; month: number; day: number} {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error('DATE_FORMAT');
  const [year, month, day] = value.split('-').map(Number);
  const dt = new Date(Date.UTC(year, month - 1, day));
  if (
    year < 1900 ||
    year > 2100 ||
    dt.getUTCFullYear() !== year ||
    dt.getUTCMonth() !== month - 1 ||
    dt.getUTCDate() !== day
  ) {
    throw new Error('INVALID_DATE');
  }
  return {year, month, day};
}

/** One specified convention: master numbers 11, 22, 33 are retained only at reduction points. */
export function reduceNumber(value: number, preserveMaster = true): number {
  if (!Number.isSafeInteger(value) || value < 0) throw new Error('INVALID_NUMBER');
  let n = value;
  while (n > 9) {
    if (preserveMaster && [11, 22, 33].includes(n)) return n;
    n = [...String(n)].reduce((sum, digit) => sum + Number(digit), 0);
  }
  return n;
}

export function calculateNumerology(birthDate: string, asOf: string): NumerologyReading {
  const born = parseISODate(birthDate);
  const today = parseISODate(asOf);
  const lifePath = reduceNumber([...birthDate.replaceAll('-', '')].reduce((a, x) => a + Number(x), 0));
  // Personal-year convention: birth month/day + target calendar year's digits (no master retention).
  const personalYear = reduceNumber(
    born.month +
      born.day +
      reduceNumber(
        [...String(today.year)].reduce((a, x) => a + Number(x), 0),
        false,
      ),
    false,
  );
  const personalMonth = reduceNumber(personalYear + today.month, false);
  return {
    schemaVersion: '1.0',
    algorithm: NUMEROLOGY_ALGORITHM,
    birthDate,
    asOf,
    lifePath,
    personalYear,
    personalMonth,
    interpretationKeys: [
      `life_path_${lifePath}`,
      `personal_year_${personalYear}`,
      `personal_month_${personalMonth}`,
    ],
    disclaimer: 'Numerology is for reflection and entertainment; it does not predict real-world outcomes.',
  };
}
