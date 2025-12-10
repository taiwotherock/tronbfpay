const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()

const StableCoinCore = artifacts.require("StableCoinCore");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const vaultAdminAddress = process.env.VAULT_ADMIN_ADDRESS;
   
    

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);


     // 1️⃣ LoanVaultCore
     //(string memory _name, string memory _symbol, uint8 _decimals, address initialAdmin, uint256 initialSupply) {
  
    await deployer.deploy(StableCoinCore, 'GBPa', 'GBPa', 6, vaultAdminAddress, 1000000000000
    );
    const stableCoinCore = await StableCoinCore.deployed();
    const stableCoinCoreAddress = tronWeb.address.fromHex(stableCoinCore.address);
    console.log("VaultLending deployed (hex):", stableCoinCore.address);
    console.log("VaultLending deployed (base58):", stableCoinCoreAddress);

    console.log("✅ All contracts deployed successfully!");
};
