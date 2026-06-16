import { describe, expect, it } from "vitest";
import {
  imageGenerationCostProperties,
  parseOpenAIImageStreamFrame,
  parseOpenAIImageStreamFrames,
} from "../src/routes/productImage.js";

describe("parseOpenAIImageStreamFrame", () => {
  it("parses OpenAI image frames with CRLF separators", () => {
    const frame = [
      "event: ignored",
      'data: {"type":"image_generation.completed","b64_json":"abc"}',
    ].join("\r\n");

    expect(parseOpenAIImageStreamFrame(frame)).toEqual({
      type: "image_generation.completed",
      b64_json: "abc",
    });
  });

  it("ignores done and malformed frames", () => {
    expect(parseOpenAIImageStreamFrame("data: [DONE]")).toBeNull();
    expect(parseOpenAIImageStreamFrame("data: {nope")).toBeNull();
    expect(parseOpenAIImageStreamFrame("event: ping")).toBeNull();
  });

  it("drains CRLF-delimited frames while preserving incomplete rest", () => {
    const buffer = [
      'data: {"type":"image_generation.partial_image","b64_json":"preview","partial_image_index":0}',
      "",
      'data: {"type":"image_generation.completed","b64_json":"final"}',
    ].join("\r\n");

    expect(parseOpenAIImageStreamFrames(buffer)).toEqual({
      events: [
        {
          type: "image_generation.partial_image",
          b64_json: "preview",
          partial_image_index: 0,
        },
      ],
      rest: 'data: {"type":"image_generation.completed","b64_json":"final"}',
    });
  });
});

describe("imageGenerationCostProperties", () => {
  it("reports explicit PostHog AI cost fields for generated images", () => {
    expect(
      imageGenerationCostProperties("gpt-image-1.5", "low", "1024x1024", 1, true),
    ).toMatchObject({
      "$ai_request_cost_usd": 0.009,
      "$ai_total_cost_usd": 0.009,
      grocer_image_model: "gpt-image-1.5",
      grocer_image_quality: "low",
      grocer_image_size: "1024x1024",
      grocer_image_count: 1,
      grocer_image_unit_price_usd: 0.009,
    });
  });

  it("omits cost totals when no image was generated", () => {
    expect(
      imageGenerationCostProperties("gpt-image-1.5", "low", "1024x1024", 1, false),
    ).toMatchObject({
      "$ai_request_cost_usd": undefined,
      "$ai_total_cost_usd": undefined,
      grocer_image_unit_price_usd: 0.009,
    });
  });
});
