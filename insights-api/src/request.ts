/**
 * Pure helpers for POST /insights/request — validation, key derivation, and
 * queue-object shaping. No I/O, no R2, no wrangler types: unit-testable with
 * plain vitest (no miniflare needed).
 */

export type GenRequest = {
  type: "movie" | "tv";
  tmdbId: number;
  season?: number;
  episode?: number;
  title: string;
  year?: number;
};

export type ValidateResult =
  | { ok: true; req: GenRequest }
  | { ok: false; reason: string };

function isPositiveInt(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v) && v > 0;
}

/** Validate an unknown request body (camelCase, as sent by the app) into a GenRequest. */
export function validateRequest(body: unknown): ValidateResult {
  if (typeof body !== "object" || body === null) {
    return { ok: false, reason: "not_an_object" };
  }
  const b = body as Record<string, unknown>;

  if (b.type !== "movie" && b.type !== "tv") {
    return { ok: false, reason: "invalid_type" };
  }
  const type = b.type;

  if (!isPositiveInt(b.tmdbId)) {
    return { ok: false, reason: "invalid_tmdb_id" };
  }
  const tmdbId = b.tmdbId;

  if (typeof b.title !== "string" || b.title.length === 0 || b.title.length > 200) {
    return { ok: false, reason: "invalid_title" };
  }
  const title = b.title;

  const hasSeason = b.season !== undefined;
  const hasEpisode = b.episode !== undefined;
  if (hasSeason !== hasEpisode) {
    return { ok: false, reason: "incomplete_episode" };
  }
  if (hasSeason && type !== "tv") {
    return { ok: false, reason: "season_episode_on_movie" };
  }
  let season: number | undefined;
  let episode: number | undefined;
  if (hasSeason) {
    if (!isPositiveInt(b.season) || !isPositiveInt(b.episode)) {
      return { ok: false, reason: "invalid_season_episode" };
    }
    season = b.season;
    episode = b.episode;
  }

  let year: number | undefined;
  if (b.year !== undefined) {
    if (typeof b.year !== "number" || !Number.isInteger(b.year)) {
      return { ok: false, reason: "invalid_year" };
    }
    year = b.year;
  }

  const req: GenRequest = { type, tmdbId, title };
  if (season !== undefined) req.season = season;
  if (episode !== undefined) req.episode = episode;
  if (year !== undefined) req.year = year;

  return { ok: true, req };
}

/** WorkItem.key format shared with the Python pipeline: movie:{id} / tv:{id} / tv:{id}:S{n}E{n}. */
export function workItemKey(req: GenRequest): string {
  if (req.season !== undefined && req.episode !== undefined) {
    return `${req.type}:${req.tmdbId}:S${req.season}E${req.episode}`;
  }
  return `${req.type}:${req.tmdbId}`;
}

/** Published R2 object key, matching the existing GET routes. */
export function publishedKey(req: GenRequest): string {
  if (req.type === "movie") {
    return `insights/movie/${req.tmdbId}.json`;
  }
  if (req.season !== undefined && req.episode !== undefined) {
    return `insights/tv/${req.tmdbId}/${req.season}/${req.episode}.json`;
  }
  return `insights/tv/${req.tmdbId}/show.json`;
}

/** Snake_case queue object written to R2 under requests/pending/{workItemKey}.json. */
export function queueObject(req: GenRequest, requestedAt: string): object {
  const out: Record<string, unknown> = {
    key: workItemKey(req),
    type: req.type,
    tmdb_id: req.tmdbId,
    title: req.title,
    requested_at: requestedAt,
  };
  if (req.season !== undefined) out.season = req.season;
  if (req.episode !== undefined) out.episode = req.episode;
  if (req.year !== undefined) out.year = req.year;
  return out;
}
