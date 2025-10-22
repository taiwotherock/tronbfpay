const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()
const AttestationRegistry = artifacts.require("AttestationRegistryV3");
const BPayEscrowVault = artifacts.require("BPayEscrowVaultV3");
const EscrowVaultProxy = artifacts.require("EscrowVaultProxyV3");
const AccessControlModule = artifacts.require("AccessControlModuleV3");
const BorderlessCreditScoreNFT = artifacts.require("BorderlessCreditScoreNFTV3");
const LiquidityPool = artifacts.require("LiquidityPoolV11");
const LoanVaultCore = artifacts.require("LoanVaultCoreV11");
const LoanManager = artifacts.require("LoanManagerV11");

module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;
    const creditOfficerAddress = process.env.CREDIT_OFFICER_ADDRESS;

    // TronWeb instance (only needed for address helpers)
    const tronWeb = new TronWeb({
        fullHost: "https://api.nileex.io"
    });

    //const deployerAddress = tronWeb.address.fromPrivateKey(deployerPK);

    // 1️⃣ AttestationRegistry
    await deployer.deploy(AttestationRegistry);
    const attestations = await AttestationRegistry.deployed();
    console.log("AttestationRegistry deployed (hex):", attestations.address);
    console.log("AttestationRegistry deployed (base58):", tronWeb.address.fromHex(attestations.address));

    // 3️⃣ EscrowVault
    await deployer.deploy(BPayEscrowVault, usdtAddress, attestations.address);
    const vault = await BPayEscrowVault.deployed();
    console.log("EscrowVault deployed (hex):", vault.address);
    console.log("EscrowVault deployed (base58):", tronWeb.address.fromHex(vault.address));


    // 4️⃣ AccessControlModule V2
    await deployer.deploy(AccessControlModule, deployerAddress, creditOfficerAddress);
    const accessControlModule = await AccessControlModule.deployed();
    const accessControlAddress = tronWeb.address.fromHex(accessControlModule.address)
    console.log("accessControlModule deployed (hex):", accessControlModule.address);
    console.log("accessControlModule deployed (base58):", tronWeb.address.fromHex(accessControlModule.address));

    // 4️⃣ BorderlessCreditScoreNFT V3
    await deployer.deploy(BorderlessCreditScoreNFT, creditOfficerAddress);
    const borderlessCreditScoreNFT = await BorderlessCreditScoreNFT.deployed();
    const borderNftAddress = tronWeb.address.fromHex(borderlessCreditScoreNFT.address);
    console.log("BorderlessCreditScoreNFT deployed (hex):", borderlessCreditScoreNFT.address);
    console.log("BorderlessCreditScoreNFT deployed (base58):", tronWeb.address.fromHex(borderlessCreditScoreNFT.address));


     // 1️⃣ LiquidityPool
    await deployer.deploy(LiquidityPool, usdtAddress,accessControlAddress);
    const liquidityPool = await LiquidityPool.deployed();
    const liquidityPoolAddress = tronWeb.address.fromHex(liquidityPool.address);
    console.log("LiquidityPool deployed (hex):", liquidityPool.address);
    console.log("LiquidityPool deployed (base58):", tronWeb.address.fromHex(liquidityPool.address));

     // 1️⃣ LoanVaultCore
    await deployer.deploy(LoanVaultCore, accessControlAddress, tronWeb.address.fromHex(liquidityPool.address));
    const loanVaultCore = await LoanVaultCore.deployed();
    const loanVaultAddress = tronWeb.address.fromHex(loanVaultCore.address);
    console.log("LoanVaultCore deployed (hex):", loanVaultCore.address);
    console.log("LoanVaultCore deployed (base58):", tronWeb.address.fromHex(loanVaultCore.address));


        const platformFeeAddress = process.env.PLATFORM_FEE_ADDRESS;
    const lenderIncomeAddress = process.env.LENDER_INCOME_ADDRESS;
     // 1️⃣ LoanManager
        //(address _accessControl, address _liquidityPool, address _vault, address _creditNFT)
        await deployer.deploy(LoanManager,accessControlAddress,liquidityPoolAddress,loanVaultAddress,borderNftAddress,
            platformFeeAddress,lenderIncomeAddress
        );
        const loanManager = await LoanManager.deployed();
        console.log("LoanManager deployed (hex):", loanManager.address);
        console.log("LoanManager deployed (base58):", tronWeb.address.fromHex(loanManager.address));
        
        


    console.log("✅ All contracts deployed successfully!");
};
