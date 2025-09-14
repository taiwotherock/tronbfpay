async function openBrowser(url: string) {
    const open = (await import("open")).default;
    await open(url);
  }

module.exports = { openBrowser };

export {};