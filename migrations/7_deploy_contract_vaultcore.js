const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()
const LoanVaultCore = artifacts.require("LoanVaultCore");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const accessControlAddress = process.env.ACCESS_CONTROL_CONTRACT_ADDRESS;
    const liquidityPoolAddress = process.env.LIQUIDITY_POOL_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);

    // 1️⃣ LoanVaultCore
    await deployer.deploy(LoanVaultCore,accessControlAddress,liquidityPoolAddress);
    const loanVaultCore = await LoanVaultCore.deployed();
    console.log("LoanVaultCore deployed (hex):", loanVaultCore.address);
    console.log("LoanVaultCore deployed (base58):", tronWeb.address.fromHex(loanVaultCore.address));

    console.log("✅ All contracts deployed successfully!");
};
