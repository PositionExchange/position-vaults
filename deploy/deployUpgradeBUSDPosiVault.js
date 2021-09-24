const {ethers, upgrades} = require("hardhat");

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

    const BUSDPosiVault = await ethers.getContractFactory("BUSDPosiVault");
    const upgraded = await upgrades.upgradeProxy('0xF3d3E84d89e3F5f79e33AC5bf6c62b1f3363234a', BUSDPosiVault);
    console.log(upgraded.address);
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error.message);
        process.exit(1);
    });