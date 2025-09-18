const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()
const LoanManager = artifacts.require("LoanManager");


module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const accessControlAddress = process.env.ACCESS_CONTROL_CONTRACT_ADDRESS;
    const liquidityPoolAddress = process.env.LIQUIDITY_POOL_CONTRACT_ADDRESS;
    const loanVaultAddress = process.env.LOAN_VAULT_CONTRACT_ADDRESS;
    const borderNftAddress = process.env.BORDERLESSCS_NFT_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);

    // 1️⃣ LoanManager
    //(address _accessControl, address _liquidityPool, address _vault, address _creditNFT)
    await deployer.deploy(LoanManager,accessControlAddress,liquidityPoolAddress,loanVaultAddress,borderNftAddress);
    const loanManager = await LoanManager.deployed();
    console.log("LoanManager deployed (hex):", loanManager.address);
    console.log("LoanManager deployed (base58):", tronWeb.address.fromHex(loanManager.address));

    console.log("✅ All contracts deployed successfully!");
};
