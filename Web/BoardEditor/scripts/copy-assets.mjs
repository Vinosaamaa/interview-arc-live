import { copyFile, mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const sourceRoot = join(
  "node_modules",
  "@excalidraw",
  "excalidraw",
  "dist",
  "excalidraw-assets",
);
const destinationRoot = join("dist", "assets", "excalidraw-assets");
const packageDistributionRoot = join(
  "node_modules",
  "@excalidraw",
  "excalidraw",
  "dist",
);
const fonts = [
  "Assistant-Bold.woff2",
  "Assistant-Medium.woff2",
  "Assistant-Regular.woff2",
  "Assistant-SemiBold.woff2",
  "Cascadia.woff2",
  "Virgil.woff2",
];

await mkdir(destinationRoot, { recursive: true });
for (const font of fonts) {
  await copyFile(join(sourceRoot, font), join(destinationRoot, font));
}

const licenseRoot = join("dist", "licenses");
await mkdir(licenseRoot, { recursive: true });
for (const entry of await readdir(packageDistributionRoot)) {
  if (!entry.endsWith(".LICENSE.txt")) continue;
  await copyFile(
    join(packageDistributionRoot, entry),
    join(licenseRoot, entry),
  );
}
for (const entry of await readdir(sourceRoot)) {
  if (!entry.endsWith(".LICENSE.txt")) continue;
  await copyFile(join(sourceRoot, entry), join(licenseRoot, entry));
}

for (const entry of await readdir(join("dist", "assets"))) {
  if (!entry.endsWith(".js") && !entry.endsWith(".css")) continue;
  const path = join("dist", "assets", entry);
  const source = await readFile(path, "utf8");
  await writeFile(path, source.replace(/[\t ]+$/gm, ""));
}
