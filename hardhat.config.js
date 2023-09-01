require('@nomicfoundation/hardhat-toolbox');
require('hardhat-docgen');
const networkConfig = require('./network.config.js');
const util = require('node:util');

const assert = (condition, message) => {
  if (condition) return;
  throw new Error(message);
}

async function deploy(contractName, signer, ...params) {
  const factory = await ethers.getContractFactory(contractName);
  const instance = await factory.connect(signer).deploy(...params);
  await instance.deployed();
  console.log(`${contractName} deployed to: ${instance.address}`);
  return instance;
}

async function getContract(contractName, deployer, nonce) {
  const predictedAddress = ethers.utils.getContractAddress({
    from: deployer.address,
    nonce,
  });
  return await ethers.getContractAt(contractName, predictedAddress);
}

task('deploy-factory', 'Deploys LootboxFactory')
.setAction(async () => {
  const { chainId } = network.config;
  assert(chainId, 'Missing network configuration!');

  const [deployer] = await ethers.getSigners();

  const { linkToken, vrfV2Wrapper } = networkConfig[chainId];

  const lootboxFactoryFactory = await ethers.getContractFactory('LootboxFactory');
  const lootboxFactory = await lootboxFactoryFactory.deploy(linkToken, vrfV2Wrapper);
  await lootboxFactory.deployed();
  console.log(`LootboxFactory deployed by ${deployer.address} to: ${lootboxFactory.address} ${network.name}`);

  // TODO: Add etherscan verification step.
});

// All the following tasks are for testing and development purpuses only.

task('deploy-lootbox', 'Deploys an ERC1155 Lootbox through a factory along with the reward tokens')
.addOptionalParam('factory', 'LootboxFactory address')
.addOptionalParam('uri', 'Lootbox metadata URI', 'https://bafybeicxxp4o5vxpesym2cvg4cqmxnwhwgpqawhhvxttrz2dlpxjyiob64.ipfs.nftstorage.link/{id}')
.addOptionalParam('id', 'Lootbox id for contract address predictability', 0, types.int)
.addOptionalParam('linkamount', 'Amount of LINK to transfer to lootbox', 100, types.int)
.setAction(async ({ factory, uri, id, linkamount }) => {
  assert(network.name == 'localhost', 'Only for testing');
  const { chainId } = network.config;
  assert(chainId, 'Missing network configuration!');

  const [deployer, supplier] = await ethers.getSigners();

  const { linkToken, linkHolder } = networkConfig[chainId];
  const link = await ethers.getContractAt('IERC20', linkToken);
  const predictedAddress = ethers.utils.getContractAddress({
    from: deployer.address,
    nonce: 0,
  });
  factory = factory || predictedAddress;

  const impersonatedLinkHolder = await ethers.getImpersonatedSigner(linkHolder);
  await(await link.connect(impersonatedLinkHolder)
    .transfer(deployer.address, ethers.utils.parseUnits('1000000'))).wait();

  const lootboxFactory = await ethers.getContractAt('LootboxFactory', factory);
  await (await lootboxFactory.deployLootbox(uri, id)).wait();
  const lootboxAddress = await lootboxFactory.getLootbox(deployer.address, id);

  console.log('Lootbox deployed to:', lootboxAddress);
  await(await link.connect(deployer)
    .transfer(lootboxAddress, ethers.utils.parseUnits(linkamount.toString()))).wait();
  console.log(`Transferred ${linkamount} LINK to the lootbox contract.`);

  const lootbox = await ethers.getContractAt('LootboxInterface', lootboxAddress);
  await (await lootbox.addSuppliers([supplier.address])).wait();
  console.log(`Supplier ${supplier.address} added to the lootbox contract.`);

  const erc20 = await deploy('MockERC20', supplier, 100000);
  const erc721 = await deploy('MockERC721', supplier, 20);
  const erc1155 = await deploy('MockERC1155', supplier, 10, 1000);
  const erc1155NFT = await deploy('MockERC1155NFT', supplier, 15);

  await (await lootbox.connect(deployer).addTokens([
    erc20.address,
    erc721.address,
    erc1155.address,
    erc1155NFT.address,
  ])).wait();
  console.log('Allowed tokens to be used as rewards in the lootbox contract.');
});

task('supply-rewards', 'Transfer rewards to the previously deployed lootbox contract')
.addOptionalParam('factory', 'LootboxFactory address')
.addOptionalParam('id', 'Lootbox id for contract address predictability', 0, types.int)
.addOptionalParam('type', 'Reward token type, ERC20, ERC721, ERC1155 or ERC1155NFT', 'ERC721')
.addOptionalParam('tokenid', 'Reward token id, not needed for ERC20', 0, types.int)
.addOptionalParam('amount', 'Reward token amount, not needed for ERC721 and ERC1155NFT', 1, types.int)
.setAction(async ({ factory, id, type, tokenid, amount }) => {
  assert(network.name == 'localhost', 'Only for testing');
  const { chainId } = network.config;
  assert(chainId, 'Missing network configuration!');

  const [deployer, supplier] = await ethers.getSigners();

  const predictedAddress = ethers.utils.getContractAddress({
    from: deployer.address,
    nonce: 0,
  });
  factory = factory || predictedAddress;

  const erc20 = await getContract('MockERC20', supplier, 0);
  const erc721 = await getContract('MockERC721', supplier, 1);
  const erc1155 = await getContract('MockERC1155', supplier, 2);
  const erc1155NFT = await getContract('MockERC1155NFT', supplier, 3);

  const lootboxFactory = await ethers.getContractAt('LootboxFactory', factory);
  const lootboxAddress = await lootboxFactory.getLootbox(deployer.address, id);

  if (type == 'ERC20') {
    await (await erc20.connect(supplier).transfer(lootboxAddress, amount)).wait();
  } else if (type == 'ERC721') {
    await (await erc721.connect(supplier)['safeTransferFrom(address,address,uint256)'](supplier.address, lootboxAddress, tokenid)).wait();
  } else if (type == 'ERC1155') {
    assert(amount > 1, 'ERC1155 should be transferred in amount > 1 to not make it ERC1155NFT in the lootbox contract.');
    await (await erc1155.connect(supplier).safeTransferFrom(supplier.address, lootboxAddress, tokenid, amount, '0x')).wait();
  } else if (type == 'ERC1155NFT') {
    await (await erc1155NFT.connect(supplier).safeTransferFrom(supplier.address, lootboxAddress, tokenid, 1, '0x')).wait();
  } else {
    throw new Error(`Unexpected reward type: ${type}`);
  }

  console.log(`Rewards supplied ${type}.`);
});

task('set-amountperunit', 'Set amount per unit of reward for a reward token')
.addOptionalParam('factory', 'LootboxFactory address')
.addOptionalParam('id', 'Lootbox id for contract address predictability', 0, types.int)
.addOptionalParam('type', 'Reward token type, ERC20, ERC721, ERC1155 or ERC1155NFT', 'ERC721')
.addOptionalParam('tokenid', 'Reward token id, not needed for ERC20', 0, types.int)
.addOptionalParam('amountperunit', 'Reward token amount per reward unit', 1, types.int)
.setAction(async ({ factory, id, type, tokenid, amountperunit }) => {
  assert(network.name == 'localhost', 'Only for testing');
  const { chainId } = network.config;
  assert(chainId, 'Missing network configuration!');

  const [deployer, supplier] = await ethers.getSigners();

  const predictedAddress = ethers.utils.getContractAddress({
    from: deployer.address,
    nonce: 0,
  });
  factory = factory || predictedAddress;

  const erc20 = await getContract('MockERC20', supplier, 0);
  const erc721 = await getContract('MockERC721', supplier, 1);
  const erc1155 = await getContract('MockERC1155', supplier, 2);
  const erc1155NFT = await getContract('MockERC1155NFT', supplier, 3);

  const lootboxFactory = await ethers.getContractAt('LootboxFactory', factory);
  const lootboxAddress = await lootboxFactory.getLootbox(deployer.address, id);
  const lootbox = await ethers.getContractAt('LootboxInterface', lootboxAddress);

  let tokenAddress;
  if (type == 'ERC20') {
    tokenAddress = erc20.address;
  } else if (type == 'ERC721') {
    tokenAddress = erc721.address;
  } else if (type == 'ERC1155') {
    tokenAddress = erc1155.address;
  } else if (type == 'ERC1155NFT') {
    tokenAddress = erc1155NFT.address;
  } else {
    throw new Error(`Unexpected reward type: ${type}`);
  }
  const oldSupply = await lootbox.unitsSupply();
  await (await lootbox.connect(deployer).setAmountsPerUnit([tokenAddress], [tokenid], [amountperunit])).wait();
  const newSupply = await lootbox.unitsSupply();

  console.log(`Amount per unit updates. Old supply: ${oldSupply} new supply: ${newSupply}`);
});

task('mint', 'Mint lootboxes')
.addOptionalParam('factory', 'LootboxFactory address')
.addOptionalParam('id', 'Lootbox id for contract address predictability', 0, types.int)
.addOptionalParam('user', 'User address that will receive lootboxes')
.addOptionalParam('tokenid', 'Token id that represents how many reward units each box will produce', 1, types.int)
.addOptionalParam('amount', 'How many lootboxes to mint', 5, types.int)
.setAction(async ({ factory, id, user: userAddr, tokenid, amount }) => {
  assert(network.name == 'localhost', 'Only for testing');
  const { chainId } = network.config;
  assert(chainId, 'Missing network configuration!');

  const [deployer, supplier, user] = await ethers.getSigners();

  const predictedAddress = ethers.utils.getContractAddress({
    from: deployer.address,
    nonce: 0,
  });
  factory = factory || predictedAddress;

  userAddr = userAddr || user.address;

  const lootboxFactory = await ethers.getContractAt('LootboxFactory', factory);
  const lootboxAddress = await lootboxFactory.getLootbox(deployer.address, id);
  const lootbox = await ethers.getContractAt('LootboxInterface', lootboxAddress);

  await (await lootbox.connect(deployer)
    .mint(userAddr, tokenid, amount, '0x')).wait();

  console.log(`${amount} lootboxes worth of ${tokenid} reward units each minted to ${userAddr}`);
});

task('fulfill', 'Set amount per unit of reward for a reward token')
.addOptionalParam('factory', 'LootboxFactory address')
.addOptionalParam('id', 'Lootbox id for contract address predictability', 0, types.int)
.addOptionalParam('user', 'User address that requested to open something')
.addOptionalParam('gas', 'Fulfillment gas limit', 2500000, types.int)
.setAction(async ({ factory, id, user: userAddr }) => {
  assert(network.name == 'localhost', 'Only for testing');
  const { chainId } = network.config;
  assert(chainId, 'Missing network configuration!');
  const { vrfV2Wrapper } = networkConfig[chainId];

  const [deployer, supplier, user] = await ethers.getSigners();

  const predictedAddress = ethers.utils.getContractAddress({
    from: deployer.address,
    nonce: 0,
  });
  factory = factory || predictedAddress;

  userAddr = userAddr || user.address;

  const lootboxFactory = await ethers.getContractAt('LootboxFactory', factory);
  const lootboxAddress = await lootboxFactory.getLootbox(deployer.address, id);
  const lootbox = await ethers.getContractAt('LootboxInterface', lootboxAddress);
  const requestId = await lootbox.openerRequests(userAddr);
  assert(requestId.gt('0'), `Open request not found for user ${userAddr}`);

  const impersonatedVRFWrapper = await ethers.getImpersonatedSigner(vrfV2Wrapper);
  const randomWord = ethers.BigNumber.from(ethers.utils.randomBytes(32));
  await (await link.connect(impersonatedVRFWrapper)
    .rawFulfillRandomWords(requestId, [randomWord], { gasLimit: gas })).wait();

  const requestIdAfter = await lootbox.openerRequests(userAddr);
  assert(requestId.eq('0'), `Randomness fulfillment ran out of gas`);

  console.log(`Randomness fulfilled successfully`);
});

task('inventory', 'Get inventory')
.addOptionalParam('factory', 'LootboxFactory address')
.addOptionalParam('id', 'Lootbox id for contract address predictability', 0, types.int)
.setAction(async ({ factory, id }) => {
  assert(network.name == 'localhost', 'Only for testing');
  const { chainId } = network.config;
  assert(chainId, 'Missing network configuration!');

  const [deployer, supplier] = await ethers.getSigners();

  const predictedAddress = ethers.utils.getContractAddress({
    from: deployer.address,
    nonce: 0,
  });
  factory = factory || predictedAddress;

  const lootboxFactory = await ethers.getContractAt('LootboxFactory', factory);
  const lootboxAddress = await lootboxFactory.getLootbox(deployer.address, id);
  const lootbox = await ethers.getContractAt('LootboxInterface', lootboxAddress);

  const inventory = await lootbox.getInventory();
  console.log(util.inspect(inventory.result, false, null, true));
  console.log(util.inspect(inventory.leftoversResult, false, null, true));
});

task('devsetup', 'Do everything')
.setAction(async (taskArgs, hre) => {
  await hre.run('deploy-factory');
  await hre.run('deploy-lootbox');
  await hre.run('supply-rewards', { tokenid: 5 });
  await hre.run('supply-rewards', { tokenid: 1 });
  await hre.run('supply-rewards', { tokenid: 9 });
  await hre.run('supply-rewards', { type: 'ERC1155', tokenid: 3, amount: 50 });
  await hre.run('supply-rewards', { type: 'ERC1155', tokenid: 3, amount: 70 });
  await hre.run('supply-rewards', { type: 'ERC1155', tokenid: 4, amount: 150 });
  await hre.run('supply-rewards', { type: 'ERC1155NFT', tokenid: 2 });
  await hre.run('supply-rewards', { type: 'ERC1155NFT', tokenid: 6 });
  await hre.run('supply-rewards', { type: 'ERC20', amount: 1000 });
  await hre.run('set-amountperunit', { type: 'ERC20', amountperunit: 30 });
  await hre.run('set-amountperunit', { type: 'ERC1155', tokenid: 3, amountperunit: 35 });
  await hre.run('set-amountperunit', { type: 'ERC1155', tokenid: 4, amountperunit: 50 });
  await hre.run('mint');
  await hre.run('inventory');
});

module.exports = {
  solidity: {
    version: '0.8.20',
    settings: {
      optimizer: { enabled: true, runs: 99 },
    },
  },
  defaultNetwork: 'localhost',
  networks: {
    localhost: {
      chainId: 31337,
      url: 'http://127.0.0.1:8545/',
    },
    hardhat: {
      allowUnlimitedContractSize: true,
      gasPrice: 100000000000,
      gas: 20000000,
      forking: {
        url: 'https://cloudflare-eth.com',
      },
      accounts: [
        {
          privateKey: '57b26bc4bcfd781dcab2fbda189bbf9eb124c7084690571ce185294cbb3d010a',
          balance: '10000000000000000000000',
        },
        {
          privateKey: '7bb779a88af05bc9bc0d0a1da4357cced604f545459a532f92c3eb6d42f1900c',
          balance: '10000000000000000000000',
        },
        {
          privateKey: '8c2fa29c9d3b9dfd7e1230296e1038f8e27d16ce4a5bbbbcb629ac8f0f00e9c9',
          balance: '10000000000000000000000',
        },
      ],
    },
    mainnet: {
      url: process.env.MAINNET_URL || 'https://cloudflare-eth.com',
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    sepolia: {
      chainId: 11155111,
      url: process.env.SEPOLIA_URL || '',
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
    goerli: {
      chainId: 5,
      url: process.env.GOERLI_URL || '',
      accounts:
        process.env.PRIVATE_KEY !== undefined ? [process.env.PRIVATE_KEY] : [],
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: 'USD',
  },
  etherscan: {
    apiKey: process.env.ETHERSCAN_API_KEY,
  },
  docgen: {
    path: './docs',
    clear: true,
    runOnCompile: false,
  },
  mocha: {
    timeout: 100000,
  },
};