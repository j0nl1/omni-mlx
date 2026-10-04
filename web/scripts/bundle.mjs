import { cp, mkdir, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const root = fileURLToPath(new URL("../", import.meta.url));
const target = fileURLToPath(
  new URL("../../Sources/AudioHTTP/Resources/AdminUI/", import.meta.url),
);
await mkdir(target, { recursive: true });
await rm(join(target, "assets"), { recursive: true, force: true });
await rm(join(target, "licenses"), { recursive: true, force: true });
await cp(join(root, "dist"), target, { recursive: true });
const lock = JSON.parse(
  await readFile(join(root, "package-lock.json"), "utf8"),
);
for (const [path, entry] of Object.entries(lock.packages)) {
  if (!path.startsWith("node_modules/") || entry.dev) continue;
  const directory = join(root, path);
  const metadata = JSON.parse(
    await readFile(join(directory, "package.json"), "utf8"),
  );
  const destination = join(
    target,
    "licenses",
    metadata.name.replaceAll("/", "__"),
  );
  await mkdir(destination, { recursive: true });
  for (const file of await readdir(directory, { withFileTypes: true })) {
    if (
      file.isFile() &&
      /^(license|notice|copying|ofl|copyright)/i.test(file.name)
    ) {
      await cp(join(directory, file.name), join(destination, file.name));
    }
  }
  await writeFile(
    join(destination, "package.json"),
    JSON.stringify(
      {
        name: metadata.name,
        version: metadata.version,
        license: metadata.license,
      },
      null,
      2,
    ) + "\n",
  );
}
console.log(
  "Bundled the administration UI and dependency license notices for SwiftPM.",
);
