const TronWeb = require('tronweb'); // 3.2.7 works with new TronWeb()
const AttestationRegistry = artifacts.require("AttestationRegistry");
const FeeSplitter = artifacts.require("FeeSplitter");
const BPayEscrowVault = artifacts.require("BPayEscrowVault");
const PaymentRouter = artifacts.require("PaymentRouter");

const BPayEscrowVaultV2 = artifacts.require("BPayEscrowVaultV2");
const PaymentRouterV2 = artifacts.require("PaymentRouterV2");

module.exports = async function(deployer) {
    const usdtAddress = process.env.USDT_CONTRACT_ADDRESS;
    const deployerAddress = process.env.PUBLIC_ADDRESS;

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

    // 2️⃣ FeeSplitter
    await deployer.deploy(FeeSplitter, usdtAddress, deployerAddress, deployerAddress);
    const splitter = await FeeSplitter.deployed();
    console.log("FeeSplitter deployed (hex):", splitter.address);
    console.log("FeeSplitter deployed (base58):", tronWeb.address.fromHex(splitter.address));

    // 3️⃣ EscrowVault
    await deployer.deploy(BPayEscrowVault, usdtAddress, attestations.address);
    const vault = await BPayEscrowVault.deployed();
    console.log("EscrowVault deployed (hex):", vault.address);
    console.log("EscrowVault deployed (base58):", tronWeb.address.fromHex(vault.address));

    // 4️⃣ PaymentRouter
    await deployer.deploy(PaymentRouter, vault.address);
    const router = await PaymentRouter.deployed();
    console.log("PaymentRouter deployed (hex):", router.address);
    console.log("PaymentRouter deployed (base58):", tronWeb.address.fromHex(router.address));


    // 3️⃣ EscrowVault V2
    await deployer.deploy(BPayEscrowVaultV2, usdtAddress, attestations.address);
    const vault2 = await BPayEscrowVaultV2.deployed();
    console.log("EscrowVault deployed (hex):", vault2.address);
    console.log("EscrowVault deployed (base58):", tronWeb.address.fromHex(vault2.address));

    // 4️⃣ PaymentRouter V2
    await deployer.deploy(PaymentRouterV2, vault2.address);
    const router2 = await PaymentRouterV2.deployed();
    console.log("PaymentRouter deployed (hex):", router2.address);
    console.log("PaymentRouter deployed (base58):", tronWeb.address.fromHex(router2.address));

    console.log("✅ All contracts deployed successfully!");
};
