const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()

const VaultLending = artifacts.require("VaultLendingV2");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;
    
     const accessControlAddress = process.env.ACCESS_CONTROL_CONTRACT_ADDRESS;
    

    

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);


     // 1️⃣ LoanVaultCore
    await deployer.deploy(VaultLending, accessControlAddress);
    const vaultLending = await VaultLending.deployed();
    const vaultLendingAddress = tronWeb.address.fromHex(vaultLending.address);
    console.log("VaultLending deployed (hex):", vaultLending.address);
    console.log("VaultLending deployed (base58):", vaultLendingAddress);

    
     
    console.log("✅ All contracts deployed successfully!");
};
