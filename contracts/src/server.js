"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const express_1 = __importDefault(require("express"));
const path_1 = __importDefault(require("path"));
const openBroswer_1 = require("./openBroswer");
const app = (0, express_1.default)();
const PORT = 5025;
// Serve static files from ./src/public
app.use(express_1.default.static(path_1.default.join(__dirname, "public")));
app.listen(PORT, async () => {
    const url = `http://localhost:${PORT}/index.html`;
    console.log(`🚀 Tron Escrow dApp running at ${url}`);
    //await open(url); // Auto-launch in default browser
    await (0, openBroswer_1.openBrowser)(url);
});
//# sourceMappingURL=server.js.map