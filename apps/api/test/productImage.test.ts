import { describe, expect, it } from "vitest";
import {
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
