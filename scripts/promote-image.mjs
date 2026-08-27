import { readFileSync, writeFileSync } from 'node:fs';

const [, , sourcePath, targetPath] = process.argv;

if (!sourcePath || !targetPath) {
  throw new Error('Usage: node scripts/promote-image.mjs SOURCE_VALUES TARGET_VALUES');
}

const source = readFileSync(sourcePath, 'utf8');
let target = readFileSync(targetPath, 'utf8');

function readSectionValue(document, section, key) {
  const pattern = new RegExp(`^${section}:\\r?\\n(?: {2}.*\\r?\\n)*? {2}${key}:\\s*["']?([^"'\\r\\n]+)["']?\\s*$`, 'm');
  const match = document.match(pattern);
  if (!match) {
    throw new Error(`Missing ${section}.${key} in ${sourcePath}`);
  }
  return match[1].trim();
}

function replaceSectionValue(document, section, key, value) {
  const sectionPattern = new RegExp(`(^${section}:\\r?\\n)((?: {2}.*\\r?\\n)*)`, 'm');
  const sectionMatch = document.match(sectionPattern);
  if (!sectionMatch) {
    throw new Error(`Missing section ${section} in ${targetPath}`);
  }

  const keyPattern = new RegExp(`(^ {2}${key}:\\s*).*$`, 'm');
  if (!keyPattern.test(sectionMatch[0])) {
    throw new Error(`Missing ${section}.${key} in ${targetPath}`);
  }

  const updatedSection = sectionMatch[0].replace(keyPattern, `$1"${value}"`);
  return document.replace(sectionPattern, updatedSection);
}

const repository = readSectionValue(source, 'image', 'repository');
const tag = readSectionValue(source, 'image', 'tag');

target = replaceSectionValue(target, 'image', 'repository', repository);
target = replaceSectionValue(target, 'image', 'tag', tag);
target = replaceSectionValue(target, 'app', 'version', tag);

writeFileSync(targetPath, target, 'utf8');
console.log(`Promoted ${repository}:${tag} from ${sourcePath} to ${targetPath}`);
