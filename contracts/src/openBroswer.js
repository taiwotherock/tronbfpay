"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.openBrowser = openBrowser;
async function openBrowser(url) {
    const open = (await import("open")).default; // dynamic import
    await open(url);
}
//# sourceMappingURL=openBroswer.js.map