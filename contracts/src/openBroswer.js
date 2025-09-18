"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
async function openBrowser(url) {
    const open = (await import("open")).default;
    await open(url);
}
module.exports = { openBrowser };
//# sourceMappingURL=openBroswer.js.map