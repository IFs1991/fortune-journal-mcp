import {requireSecret} from '@/src/domain/security';

/** Independent server secrets (never shared between purposes). Throws SECRET_NOT_CONFIGURED. Server only. */
type Secret = 'REQUEST_HMAC_KEY' | 'TAROT_HMAC_KEY' | 'OPS_HMAC_KEY' | 'ATTRIBUTION_HMAC_KEY' | 'CRON_SECRET';

export function secret(name: Secret): string {
  return requireSecret(process.env[name]);
}
