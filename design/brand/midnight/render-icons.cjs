// Regenerates the app's raster icons from icon.svg. Run from the repo root:
//   node design/brand/midnight/render-icons.cjs
// Needs a local Chrome or Edge for headless rendering.
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '../../..');
const app = path.join(root, 'apps/vault');
const browser = [
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
].find((p) => fs.existsSync(p));
if (!browser) throw new Error('Chrome or Edge is required.');

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'midnight-icons-'));
const svg = fs.readFileSync(path.join(__dirname, 'icon.svg'), 'utf8');

function render(size) {
  const html = path.join(work, `${size}.html`);
  const png = path.join(work, `${size}.png`);
  fs.writeFileSync(
    html,
    `<!doctype html><style>html,body{margin:0;background:transparent}svg{display:block;width:512px;height:512px}</style>${svg}`,
  );
  execFileSync(browser, [
    '--headless=new',
    '--disable-gpu',
    '--hide-scrollbars',
    // Headless Chrome will not shrink its window below ~500px, so draw at
    // 512 CSS px and scale the device pixels down to the target size.
    `--force-device-scale-factor=${size / 512}`,
    '--default-background-color=00000000',
    `--user-data-dir=${path.join(work, `profile-${size}`)}`,
    '--window-size=512,512',
    `--screenshot=${png}`,
    `file:///${html.replace(/\\/g, '/')}`,
  ], { stdio: 'ignore' });
  // On Windows chrome.exe can hand off to a child and exit before the
  // screenshot exists, so wait for the file to appear.
  const deadline = Date.now() + 30_000;
  while (!fs.existsSync(png) || fs.statSync(png).size === 0) {
    if (Date.now() > deadline) throw new Error(`Chrome did not render ${size}px.`);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 200);
  }
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 300);
  return fs.readFileSync(png);
}

const android = { mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 };
for (const [density, size] of Object.entries(android)) {
  fs.writeFileSync(
    path.join(app, `android/app/src/main/res/mipmap-${density}/ic_launcher.png`),
    render(size),
  );
}

// PNG-compressed ICO entries are supported on Windows Vista and later.
const icoSizes = [16, 24, 32, 48, 64, 128, 256];
const images = icoSizes.map(render);
const header = Buffer.alloc(6 + 16 * images.length);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(images.length, 4);
let offset = header.length;
images.forEach((image, i) => {
  const entry = 6 + 16 * i;
  const size = icoSizes[i] === 256 ? 0 : icoSizes[i];
  header.writeUInt8(size, entry);
  header.writeUInt8(size, entry + 1);
  header.writeUInt16LE(1, entry + 4);
  header.writeUInt16LE(32, entry + 6);
  header.writeUInt32LE(image.length, entry + 8);
  header.writeUInt32LE(offset, entry + 12);
  offset += image.length;
});
fs.writeFileSync(
  path.join(app, 'windows/runner/resources/app_icon.ico'),
  Buffer.concat([header, ...images]),
);

fs.rmSync(work, { recursive: true, force: true });
console.log('Wrote Android mipmaps and Windows app_icon.ico.');
