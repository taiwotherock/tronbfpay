const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()
const BorderlessCreditScoreNFT = artifacts.require("BorderlessCreditScoreNFT");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const accessControlAddress = process.env.ACCESS_CONTROL_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);

    // 1️⃣ BorderlessCreditScoreNFT
    await deployer.deploy(BorderlessCreditScoreNFT,deployerAddress);
    const borderlessCreditScoreNFT = await BorderlessCreditScoreNFT.deployed();
    console.log("BorderlessCreditScoreNFT deployed (hex):", borderlessCreditScoreNFT.address);
    console.log("BorderlessCreditScoreNFT deployed (base58):", tronWeb.address.fromHex(borderlessCreditScoreNFT.address));

    console.log("✅ All contracts deployed successfully!");
};
