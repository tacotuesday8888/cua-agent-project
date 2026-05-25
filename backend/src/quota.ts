/// Pure usage-cap logic, kept free of Firestore so it can be unit-tested.

/** Default per-user monthly request cap for the hosted free tier. */
export const DEFAULT_MONTHLY_REQUEST_CAP = 1000;

/** A stable "YYYY-MM" key (UTC) used to bucket monthly usage. */
export function monthKey(date: Date = new Date()): string {
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  return `${year}-${month}`;
}

/** Whether a user who has already made `used` requests this month is at/over the cap. */
export function isOverCap(used: number, cap: number = DEFAULT_MONTHLY_REQUEST_CAP): boolean {
  return used >= cap;
}
