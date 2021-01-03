// Copyright 2020 Mitchell Kember. Subject to the MIT License.

import { MuxAsyncIterator } from "https://deno.land/std/async/mod.ts";
import { exists } from "https://deno.land/std/fs/mod.ts";
import { dirname, resolve } from "https://deno.land/std/path/mod.ts";
import { signal } from "https://deno.land/std/signal/mod.ts";
import katex from "https://cdn.jsdelivr.net/npm/katex@0.12.0/dist/katex.mjs";

// Name of this script, used in logs.
const SCRIPT_NAME = "katex.ts";

// Prints the usage message using the given writing function.
function usage(write: (s: string) => void) {
  write(
    `
usage: deno run --unstable --allow-read --allow-write
       ${SCRIPT_NAME} [--help | --wait] SOCKET_FILE

Runs a server that renders TeX into KaTeX HTML.

The server listens on the Unix domain socket SOCKET_FILE (stream-oriented).
Inputs and outputs are null terminated. The input prefix "display:" enables
display mode. The server automatically exits if SOCKET_FILE is removed.

When run with the --wait option, waits for a server to start.
`.trim(),
  );
}

// Error that causes the program to clean up and exit.
class ExitError extends Error {
  constructor(readonly code: number) {
    super();
  }
}

// Files to remove before exiting.
const filesToRemove: string[] = [];

// Removes files in filesToRemove if they exist.
async function cleanup(): Promise<void> {
  try {
    await Promise.allSettled(filesToRemove.map((f) => Deno.remove(f)));
  } catch (ex) {
    if (!(ex instanceof Deno.errors.NotFound)) {
      throw ex;
    }
  }
}

// Termination signals that we want to handle.
const SIGNUMS = [
  Deno.Signal.SIGHUP,
  Deno.Signal.SIGINT,
  Deno.Signal.SIGTERM,
];

// Upon receiving one of the signals in SIGNUMS, throws ExitError.
async function handleSignals(): Promise<never> {
  return Promise.race(SIGNUMS.map((sig) =>
    (async () => {
      await Deno.signal(sig);
      // Simulate the exit status for this signal. Really we should re-raise and
      // let the default handler exit, but the only way to do this seems to be
      // `Deno.kill(Deno.pid, sig)` which requires --allow-run.
      throw new ExitError(128 + sig);
    })()
  ));
}

// Prefix used to request display mode.
const DISPLAY_PREFIX = "display:";

// Responds to null-terminated TeX messages with null-terminated KaTeX HTML.
async function serveKatex(listener: Deno.Listener): Promise<void> {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  for await (const conn of listener) {
    let buffer = "";
    for await (const chunk of Deno.iter(conn)) {
      const parts = decoder.decode(chunk).split("\x00");
      parts[0] = buffer + parts[0];
      buffer = parts.pop()!;
      for (const part of parts) {
        const displayMode = part.startsWith(DISPLAY_PREFIX);
        const tex = displayMode ? part.slice(DISPLAY_PREFIX.length) : part;
        const output =
          katex.renderToString(tex, { displayMode, throwOnError: false }) +
          "\x00";
        await Deno.writeAll(conn, encoder.encode(output));
      }
    }
  }
}

// Waits for the given file to be created (if it doesn't already exist).
async function waitForFile(path: string): Promise<void> {
  if (await exists(path)) {
    return;
  }
  const absolute = resolve(path);
  for await (const event of Deno.watchFs(dirname(path), { recursive: false })) {
    // We don't check event.kind on purpose. It might be "remove" in the race
    // condition where startServer creates the file in between the exists check
    // above and this watchFS loop.
    if (event.paths.includes(absolute)) {
      return;
    }
  }
}

// Throws ExitError(0) when the given file is removed.
async function whileFileExists(path: string): Promise<never> {
  for await (const event of Deno.watchFs(path)) {
    if (event.kind === "remove") {
      throw new ExitError(0);
    }
  }
  throw Error("watchFS stopped!");
}

// Starts the server on socketFile. Throws ExitError if socketFile already
// exists, or if it is removed while the server is running.
async function startServer(socketFile: string): Promise<void> {
  if (await exists(socketFile)) {
    console.error(`error: ${socketFile} already exists`);
    throw new ExitError(1);
  }
  filesToRemove.push(socketFile);
  // Create a regular file first so that --wait will see an event. (Creation via
  // the listen call does not cause an FS event.) We call fsync to ensure each
  // step is committed, otherwise it might not register at all, or watchFS might
  // get an event for this very removal and exit the program.
  const parent = await Deno.open(dirname(socketFile));
  const regularFile = await Deno.create(socketFile);
  await Deno.fsync(regularFile.rid);
  await Deno.fsync(parent.rid);
  await Deno.remove(socketFile);
  await Deno.fsync(parent.rid);
  parent.close();
  const listener = Deno.listen({ transport: "unix", path: socketFile });
  console.log(`${SCRIPT_NAME}: listening on ${socketFile}`);
  return Promise.race([
    serveKatex(listener),
    whileFileExists(socketFile),
  ]);
}

async function main() {
  const args = [...Deno.args];
  if (args.includes("-h") || args.includes("--help")) {
    usage(console.log);
    return;
  }
  const waitIdx = args.indexOf("--wait");
  if (waitIdx >= 0) {
    args.splice(waitIdx, 1);
  }
  if (args.length != 1) {
    usage(console.error);
    Deno.exit(1);
  }
  const socketFile = args[0];
  if (waitIdx >= 0) {
    return waitForFile(socketFile);
  }
  let exitCode = 0;
  try {
    await Promise.race([
      handleSignals(),
      startServer(socketFile),
    ]);
  } catch (ex) {
    if (ex instanceof ExitError) {
      exitCode = ex.code;
    } else {
      throw ex;
    }
  } finally {
    await cleanup();
  }
  Deno.exit(exitCode);
}

main();
