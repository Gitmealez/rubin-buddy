// Use the exact app artwork and timings in the interactive website preview.
const fs = require('node:fs');
const path = require('node:path');
const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, 'frames/manifest.json')));
const images = {};
for (const animation of Object.values(manifest.animations)) {
  for (const frame of animation.frames) {
    images[frame.file] = 'data:image/png;base64,' + fs.readFileSync(path.join(__dirname, 'frames', frame.file)).toString('base64');
  }
}
fs.writeFileSync(path.join(__dirname, 'site/preview-data.js'), 'window.RICK_PREVIEW = ' + JSON.stringify({ ...manifest, images }) + ';\n');
for (const [to, from] of Object.entries({'idle.png':'idle-0.png','working.png':'think-0.png','waiting.png':'look-0.png','seated.png':'meditate-0.png','icon.png':'menubar.png'})) {
  fs.copyFileSync(path.join(__dirname, 'frames', from), path.join(__dirname, 'site', to));
}
// The stable website address rescues source installs when a GitHub owner moves.
// Keep the full guarded installer here, not a second streaming shell pipeline.
fs.copyFileSync(path.join(__dirname, 'install.sh'), path.join(__dirname, 'site/install.sh'));
console.log('Website preview and installer synchronized.');
