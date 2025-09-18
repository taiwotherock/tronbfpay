const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()
const LiquidityPool = artifacts.require("LiquidityPool");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const accessControlAddress = process.env.ACCESS_CONTROL_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);

    // 1️⃣ LiquidityPool
    await deployer.deploy(LiquidityPool,usdtAddress,accessControlAddress);
    const liquidityPool = await LiquidityPool.deployed();
    console.log("LiquidityPool deployed (hex):", liquidityPool.address);
    console.log("LiquidityPool deployed (base58):", tronWeb.address.fromHex(liquidityPool.address));

    console.log("✅ All contracts deployed successfully!");
};
