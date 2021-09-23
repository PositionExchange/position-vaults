const {version} = require('chai');
const {hre, upgrades, ethers} = require('hardhat')

async function verifyContract(address, args, contract) {
    const verifyObj = {address}
    if (args) {
        verifyObj.constructorArguments = args
    }
    if (contract) {
        verifyObj.contract = contract;
    }
    console.log("verifyObj", verifyObj)
    return hre
        .run("verify:verify", verifyObj)
        .then(() =>
            console.log(
                "Contract address verified:",
                address
            )
        );
}

async function processTransactionAndWait(tx, w = 5) {
    return tx.wait(w)
}

async function main() {

    const BNBPosiVault = await ethers.getContractFactory('BNBPosiVault');
    console.log('Deploying Box...');
    const BNBVaultContract = await upgrades.deploy(BNBPosiVault);
    await BNBVaultContract.deployed();
    console.log('BUSDVaultContract deployed to:', BNBVaultContract.address);

}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error.message);
        process.exit(1);
    });