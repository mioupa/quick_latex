'use strict';
const os = require('os');
const path = require('path');

// Shared with the Quick LaTeX app and the CLI.
const supportDir = path.join(os.homedir(), 'Library', 'Application Support', 'QuickLaTeX');

module.exports = {
  supportDir,
  scratchPath: path.join(supportDir, 'scratch.tex'),
  preamblePath: path.join(supportDir, 'preamble.tex'),
};
