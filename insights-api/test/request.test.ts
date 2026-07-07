import { describe, it, expect } from "vitest";
import { validateRequest, workItemKey, publishedKey, queueObject } from "../src/request";

describe("validateRequest", () => {
  it("accepts a valid episode request", () => {
    const r = validateRequest({ type: "tv", tmdbId: 125988, season: 1, episode: 1, title: "Silo", year: 2023 });
    expect(r.ok).toBe(true);
  });
  it("rejects unknown type", () => {
    expect(validateRequest({ type: "song", tmdbId: 1, title: "x" }).ok).toBe(false);
  });
  it("rejects missing id", () => {
    expect(validateRequest({ type: "movie", title: "x" }).ok).toBe(false);
  });
  it("rejects half an episode (season without episode)", () => {
    expect(validateRequest({ type: "tv", tmdbId: 1, season: 1, title: "x" }).ok).toBe(false);
  });
  it("rejects oversized title", () => {
    expect(validateRequest({ type: "movie", tmdbId: 1, title: "x".repeat(201) }).ok).toBe(false);
  });
});

describe("keys", () => {
  const ep = { type: "tv", tmdbId: 125988, season: 1, episode: 1, title: "Silo" } as const;
  it("work-item key", () => expect(workItemKey(ep)).toBe("tv:125988:S1E1"));
  it("published key episode", () => expect(publishedKey(ep)).toBe("insights/tv/125988/1/1.json"));
  it("published key movie", () =>
    expect(publishedKey({ type: "movie", tmdbId: 27205, title: "I" })).toBe("insights/movie/27205.json"));
  it("published key show", () =>
    expect(publishedKey({ type: "tv", tmdbId: 125988, title: "S" })).toBe("insights/tv/125988/show.json"));
  it("queue object is snake_case with requested_at", () =>
    expect(queueObject(ep, "2026-07-07T20:00:00Z")).toMatchObject(
      { key: "tv:125988:S1E1", tmdb_id: 125988, requested_at: "2026-07-07T20:00:00Z" }));
});
