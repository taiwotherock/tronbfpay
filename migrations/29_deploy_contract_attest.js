const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()

const BNPLAttestationOracle = artifacts.require("BNPLAttestationOracle");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;
    
     const accessControlAddress = process.env.ACCESS_CONTROL_CONTRACT_ADDRESS;
    

    

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);


     // 1️⃣ bnplLAttestationOracle
    await deployer.deploy(BNPLAttestationOracle);
    const bnplLAttestationOracle = await BNPLAttestationOracle.deployed();
    const bnplAddress = tronWeb.address.fromHex(bnplLAttestationOracle.address);
    console.log("VaultLending deployed (hex):", bnplLAttestationOracle.address);
    console.log("VaultLending deployed (base58):", bnplAddress);

    
     
    console.log("✅ All contracts deployed successfully!");
};
