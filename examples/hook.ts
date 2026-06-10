#!/usr/bin/env bun
//
// Minimal example: write a WezTerm attention marker from a CLI hook.
// Adapt this for any tool that wants to signal "I'm done" or "look at me"
// to the WezTerm tab bar.
//
// Protocol:
//   Write {"type":"<state>"} to ~/.local/state/wezterm-attention/<WEZTERM_PANE>
//   Valid types: "thinking", "stop", "notify", "review"
//   Optional: {"type":"thinking","frame":0} — bump frame on each write to keep
//   the marker alive past the plugin's thinking_ttl. The spinner animation
//   itself is time-driven by the plugin; frame is just a heartbeat nonce.
//
// The WEZTERM_PANE env var is set automatically by WezTerm for every shell.

import { mkdir, writeFile, rename } from "node:fs/promises";
import { join } from "node:path";

type AttentionType = "thinking" | "stop" | "notify" | "review";

async function writeMarker(type: AttentionType, frame?: number): Promise<void> {
  const paneId = process.env.WEZTERM_PANE;
  const home = process.env.HOME;
  if (!paneId || !home) return;

  const dir = join(home, ".local", "state", "wezterm-attention");
  await mkdir(dir, { recursive: true });

  const data: Record<string, unknown> = { type };
  if (frame !== undefined) data.frame = frame;

  // Atomic write: unique tmp name + rename. A fixed tmp name would let
  // concurrent writers trample each other's half-written files.
  const file = join(dir, paneId);
  const tmp = `${file}.${process.pid}.tmp`;
  await writeFile(tmp, JSON.stringify(data));
  await rename(tmp, file);
}

// Example: signal that work is done
await writeMarker("stop");
