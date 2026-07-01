import { Effect } from "effect";

/**
 * Lifts a thunk returning a value-or-promise into an Effect whose rejection is a
 * *defect* — the exact semantics of a bare `await leaf()` in the pre-Effect
 * code: the happy path yields the value, a rejection bubbles to Hono's
 * `onError` (500) rather than into the typed channel.
 *
 * Unlike `Effect.promise`, it tolerates a thunk that returns a plain value
 * instead of a Promise (e.g. a `vi.fn()` test double), because `await` did too.
 * Use this for leaf D1/APNs/R2 calls whose failure should surface as a 500.
 */
export const fromPromise = <A>(
  thunk: () => A | Promise<A>,
): Effect.Effect<Awaited<A>> =>
  Effect.promise(() => Promise.resolve(thunk()));

/**
 * Like {@link fromPromise}, but a rejection becomes a *typed* failure (the
 * rejection value) rather than a defect — so it can be recovered with
 * `Effect.catchAll`. Use this where the pre-Effect code wrapped an `await` in a
 * `try/catch` that swallowed or downgraded the error (e.g. a soft cache lookup,
 * or a generation failure that degrades to a 502).
 */
export const attemptPromise = <A>(
  thunk: () => A | Promise<A>,
): Effect.Effect<Awaited<A>, unknown> =>
  Effect.tryPromise({
    try: () => Promise.resolve(thunk()),
    catch: (error) => error,
  });
