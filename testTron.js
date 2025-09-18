const { TronWeb } = require('tronweb');

const tronWeb = new TronWeb({
    fullHost: 'https://api.shasta.trongrid.io',
    privateKey: 'YOUR_PRIVATE_KEY'
});

tronWeb.trx.getCurrentBlock().then(block => {
    console.log("Connected to Tron, current block:", block.block_header.raw_data.number);
}).catch(console.error);
