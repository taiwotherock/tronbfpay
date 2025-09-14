const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()
const AccessControlModule = artifacts.require("AccessControlModule");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);

    // 1️⃣ AccessControlModule
    await deployer.deploy(AccessControlModule,deployerAddress,deployerAddress);
    const accessControlModule = await AccessControlModule.deployed();
    console.log("AccessControlModule deployed (hex):", accessControlModule.address);
    console.log("AccessControlModule deployed (base58):", tronWeb.address.fromHex(accessControlModule.address));

    console.log("✅ All contracts deployed successfully!");
};
