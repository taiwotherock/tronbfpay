const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()
const P2PExchange = artifacts.require("P2PExchange");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;


    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);

    // 1️⃣ P2PExchange
    //(address _accessControl, address _liquidityPool, address _vault, address _creditNFT)
    await deployer.deploy(P2PExchange,usdtAddress
    );
    const p2pExchange = await P2PExchange.deployed();
    console.log("P2PExchange deployed (hex):", p2pExchange.address);
    console.log("P2PExchange deployed (base58):", tronWeb.address.fromHex(p2pExchange.address));

    console.log("✅ All contracts deployed successfully!");
};
