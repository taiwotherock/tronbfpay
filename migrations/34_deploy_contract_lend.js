const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()

const VaultLending = artifacts.require("VaultLendingV6");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;
    const attestationAddress = process.env.ATTESTATION_ADDRESS;
    const treasuryAddress = process.env.PLATFORM_TREASURY_ADDRESS;
    const vaultAdminAddress = process.env.VAULT_ADMIN_ADDRESS;
    const creditOfficerAddress = process.env.CREDIT_OFFICER_ADDRESS;
    const accessControlAddress = process.env.ACCESS_CONTROL_CONTRACT_ADDRESS;
    

   
    

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);


     // 1️⃣ LoanVaultCore

    await deployer.deploy(VaultLending, usdtAddress,attestationAddress,
        treasuryAddress,vaultAdminAddress,creditOfficerAddress,6,"UBNPL","BNPL Liquidity Pool"
    );
    const vaultLending = await VaultLending.deployed();
    const vaultLendingAddress = tronWeb.address.fromHex(vaultLending.address);
    console.log("VaultLending deployed (hex):", vaultLending.address);
    console.log("VaultLending deployed (base58):", vaultLendingAddress);

    
     
    console.log("✅ All contracts deployed successfully!");
};
