import { cp, copyFile, mkdir, rm } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const editorRoot = join(scriptDirectory, "..");
const repositoryRoot = join(editorRoot, "..", "..");
const distributionRoot = join(editorRoot, "dist");
const resourceRoot = join(
  repositoryRoot,
  "Sources",
  "InterviewArcLive",
  "Resources",
  "BoardEditor",
);

await rm(resourceRoot, { recursive: true, force: true });
await mkdir(resourceRoot, { recursive: true });
await cp(distributionRoot, resourceRoot, { recursive: true });
await copyFile(
  join(repositoryRoot, "THIRD_PARTY_NOTICES.md"),
  join(resourceRoot, "THIRD_PARTY_NOTICES.md"),
);
