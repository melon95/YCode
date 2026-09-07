import { describe, expect, it } from "vitest";
import {
  outputImpliesResumed,
  RESUME_OUTPUT_BYTES,
  statusFromLight,
} from "./sessionStatus";

describe("statusFromLight", () => {
  it("没有信号的会话是空闲,不是等你处理", () => {
    expect(statusFromLight(undefined)).toBe("idle");
  });

  it("waiting 映射到 blocked —— 唯一需要用户动手的状态", () => {
    expect(statusFromLight("waiting")).toBe("blocked");
    expect(statusFromLight("running")).toBe("working");
    expect(statusFromLight("done")).toBe("done");
    expect(statusFromLight("error")).toBe("error");
  });
});

describe("outputImpliesResumed", () => {
  // 这是「在 ycode 之外答复」的兜底判据。收紧下界会让收尾重绘被误当成
  // 用户答复(灯在读到之前就灭),放宽上界会让灯永远撤不下来。
  it("turn-complete 之后的收尾重绘不算答复", () => {
    expect(outputImpliesResumed(0)).toBe(false);
    expect(outputImpliesResumed(200)).toBe(false); // 提示框重绘
    expect(outputImpliesResumed(1024)).toBe(false); // 啰嗦些的插件提示
    expect(outputImpliesResumed(RESUME_OUTPUT_BYTES - 1)).toBe(false);
  });

  it("越过阈值就认定 agent 又开始干活了", () => {
    expect(outputImpliesResumed(RESUME_OUTPUT_BYTES)).toBe(true);
    expect(outputImpliesResumed(64 * 1024)).toBe(true);
  });
});
