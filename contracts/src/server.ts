/*import express from "express";
import path from "path";
import { openBrowser } from "./openBroswer";
*/

const express = require("express");
const path = require("path");
const { openBrowser } = require("./openBrowser");

const app = express();
const PORT = 5025;

// Serve static files from ./src/public
app.use(express.static(path.join(__dirname, "public")));

app.listen(PORT, async () => {
  const url = `http://localhost:${PORT}/index.html`;
  console.log(`🚀 Tron Escrow dApp running at ${url}`);
  //await open(url); // Auto-launch in default browser
  await openBrowser(url);
});


export {};