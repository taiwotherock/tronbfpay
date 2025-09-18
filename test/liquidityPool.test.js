const { TronWeb } = require('tronweb');
const { assert } = require('chai');
const fs = require('fs');
const path = require('path');
require('dotenv').config();


// TronWeb Setup (change for your local node or Shasta testnet)
const tronWeb = new TronWeb({
    fullHost: "https://api.nileex.io",
    privateKey: process.env.PRIVATE_KEY_NILE // Replace with dev key
});

// Load compiled contract artifacts (ABI + Bytecode)
//const liquidityPoolJSON = JSON.parse(fs.readFileSync(path.join(__dirname, '../build/contracts/LiquidityPool.json')));
//const accessControlMockJSON = JSON.parse(fs.readFileSync(path.join(__dirname, '../build/contracts/AccessControlModule.json')));
//const tokenArtifact = JSON.parse(fs.readFileSync(path.join(__dirname, '../build/contracts/TRC20.json')));

const tokenArtifact = JSON.parse(
    fs.readFileSync('./build/contracts/SafeTRC20.json', 'utf8')
);
const poolArtifact =JSON.parse(
    fs.readFileSync('./build/contracts/LiquidityPool.json', 'utf8')
);

const acessControlArtifact =JSON.parse(
    fs.readFileSync('./build/contracts/AccessControlModule.json', 'utf8')
);

let accounts, liquidityPool, accessControlContract, token,liquidityPoolContract, tokenContract;

describe('LiquidityPool Integration Tests', function () {
    this.timeout(90000); // Longer timeout for contract deployments

    before(async () => {
        // Get test accounts

        //const privateKey = process.env.PRIVATE_KEY_NILE
        /*if (!privateKey) {
            // Generate for testing (you'll need to fund this account)
            privateKey = TronWeb.utils.crypto.generatePrivateKey();
            console.log('🔑 Generated test private key:', privateKey);
            console.log('📍 Fund this address with test TRX:', TronWeb.address.fromPrivateKey(privateKey));
            console.log('🚰 Get test TRX from: https://www.trongrid.io/faucet');
        }*/

         // Initialize TronWeb
         /*tronWeb = new TronWeb({
            fullHost: 'https://api.nileex.io',
            privateKey: privateKey
        });*/

        /*const account1 = await tronWeb.createAccount();
    const account2 = await tronWeb.createAccount();
    
    accounts = [
        account1.address.base58,
        account2.address.base58
    ];*/

     // Verify initialization
     if (!tronWeb.defaultAddress?.base58) {
        throw new Error('TronWeb initialization failed - no default address');
    }

    accounts = [tronWeb.defaultAddress.base58];
    console.log('✅ Using account:', accounts[0]);

    // Check balance
    try {
        const balance = await tronWeb.trx.getBalance(accounts[0]);
        console.log('💰 Account balance:', tronWeb.fromSun(balance), 'TRX');
        
        if (balance < tronWeb.toSun(100)) { // Need at least 100 TRX for deployment
            throw new Error('Insufficient TRX balance for deployment. Get test TRX from https://www.trongrid.io/faucet');
        }
    } catch (balanceError) {
        console.error('Could not check balance:', balanceError.message);
    }

        //accounts = await tronWeb.trx.getAccounts();

        // Deploy Mock Token with 1,000,000 initial supply
        /*const TokenContract = await tronWeb.contract(TokenMockJSON.abi);
        token = await TokenContract.new(1_000_000).send({ from: accounts[0] });

        // Deploy AccessControlMock and set admin
        const AccessControlContract = await tronWeb.contract(AccessControlMockJSON.abi);
        accessControl = await AccessControlContract.new().send({ from: accounts[0] });
        await accessControl.methods.setAdmin(accounts[0], true).send({ from: accounts[0] });

        // Deploy LiquidityPool with Token + AccessControl addresses
        const LiquidityPoolContract = await tronWeb.contract(LiquidityPoolJSON.abi);
        liquidityPool = await LiquidityPoolContract.new(token.address, accessControl.address).send({ from: accounts[0] });
        */

        try {
            // Deploy Token Contract
            console.log('Deploying Token contract...');
            tokenContract = await tronWeb.contract().new({
                abi: tokenArtifact.abi,
                bytecode: tokenArtifact.bytecode,
                parameters: [
                    "Test Token", 
                    "TEST", 
                    tronWeb.toSun(1000000) // 1M tokens
                ],
                feeLimit: tronWeb.toSun(1000), // 1000 TRX
                callValue: 0
            });

            console.log('Token deployed at:', tokenContract.address);

            // Deploy Access Control Contract
            console.log('Deploying Access Control contract...');
            accessControlContract = await tronWeb.contract().new({
                abi: acessControlArtifact.abi,
                bytecode: acessControlArtifact.bytecode,
                parameters: [
                    accounts[0],
                    accounts[0]
                    
                ],
                feeLimit: tronWeb.toSun(1000), // 1000 TRX
                callValue: 0
            });

            console.log('Access Control deployed at:', tokenContract.address);

            // Deploy Liquidity Pool Contract  
            console.log('Deploying LiquidityPool contract...');
            liquidityPoolContract = await tronWeb.contract().new({
                abi: poolArtifact.abi,
                bytecode: poolArtifact.bytecode,
                parameters: [tokenContract.address,accessControlContract.address],
                feeLimit: tronWeb.toSun(1000),
                callValue: 0
            });

            console.log('LiquidityPool deployed at:', liquidityPoolContract.address);

        } catch (error) {
            console.error('Deployment failed:', error);
            throw error;
        }

    });

    it("should deposit tokens successfully", async function() {
        this.timeout(10000);
        
        // Your test logic here
        const depositAmount = tronWeb.toSun(100); // 100 tokens

        console.log('token address ' + tokenContract.address)

        if (typeof tokenContract.methods.approve !== 'function') {
            throw new Error('Token contract approve method not available');
        }
        
        // Approve tokens first
        await tokenContract.methods.approve(
            liquidityPoolContract.address, 
            depositAmount
        ).send({
            feeLimit: tronWeb.toSun(100)
        });

        // Then deposit
        const result = await liquidityPoolContract.deposit(depositAmount).send({
            feeLimit: tronWeb.toSun(100)
        });

        console.log('Deposit successful:', result);
    });

    it('should whitelist a user for withdrawal', async function() {
        this.timeout(10000);
        
        // Set withdrawal whitelist for accounts[0]
        const whitelistTx = await liquidityPool.setWithdrawWhitelist(accounts[0], true).send({
            feeLimit: tronWeb.toSun(100), // 100 TRX fee limit
            callValue: 0,
            shouldPollResponse: true
        });
        
        console.log('Whitelist transaction:', whitelistTx);
    
        // Check if user is whitelisted
        const isWhitelisted = await liquidityPool.withdrawWhitelist(accounts[0]).call();
        assert.isTrue(isWhitelisted, 'Whitelist not set correctly');
    });
    
    it('should allow withdrawals for whitelisted user', async function() {
        this.timeout(10000);
        
        // Withdraw 200 tokens
        const withdrawTx = await liquidityPool.withdraw(tokenContract.address, 200).send({
            feeLimit: tronWeb.toSun(100),
            callValue: 0,
            shouldPollResponse: true
        });
        
        console.log('Withdrawal transaction:', withdrawTx);
    
        // Check remaining deposit should be 300
        const remaining = await liquidityPool.deposits(accounts[0], tokenContract.address).call();
        assert.equal(remaining.toString(), '300', 'Withdrawal did not reduce deposit balance correctly');
    });
    
    it('should pause and unpause the contract', async function() {
        this.timeout(15000);
        
        // Pause the contract
        const pauseTx = await liquidityPool.pause().send({
            feeLimit: tronWeb.toSun(100),
            callValue: 0,
            shouldPollResponse: true
        });
        
        console.log('Pause transaction:', pauseTx);
        
        // Check if contract is paused
        let paused = await liquidityPool.paused().call();
        assert.isTrue(paused, 'Contract did not pause');
    
        // Unpause the contract
        const unpauseTx = await liquidityPool.unpause().send({
            feeLimit: tronWeb.toSun(100),
            callValue: 0,
            shouldPollResponse: true
        });
        
        console.log('Unpause transaction:', unpauseTx);
        
        // Check if contract is unpaused
        paused = await liquidityPool.paused().call();
        assert.isFalse(paused, 'Contract did not unpause');
    });
  

    
});
