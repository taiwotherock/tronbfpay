const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()

const OverdraftLineVault = artifacts.require("OverdraftLineVault");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const vaultAdminAddress = process.env.VAULT_ADMIN_ADDRESS;
   
    

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);


     // 1️⃣ LoanVaultCore
  
    await deployer.deploy(OverdraftLineVault, vaultAdminAddress, usdtAddress,6,6
    );
    const overdraftLineVault = await OverdraftLineVault.deployed();
    const overdraftLineVaultAddress = tronWeb.address.fromHex(overdraftLineVault.address);
    console.log("VaultLending deployed (hex):", overdraftLineVault.address);
    console.log("VaultLending deployed (base58):", overdraftLineVaultAddress);

    console.log("✅ All contracts deployed successfully!");
};
