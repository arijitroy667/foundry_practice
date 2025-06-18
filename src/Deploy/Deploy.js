const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");
require("dotenv").config({ path: path.resolve(__dirname, "../../.env") });

// Keep a cache of loaded artifacts
const artifactCache = new Map();

// Load ABIs (You'll need to compile your contracts first and have the ABIs available)
// Helper function to load contract artifacts
function loadArtifact(contractName) {
  // Return from cache if available
  if (artifactCache.has(contractName)) {
    return artifactCache.get(contractName);
  }

  const artifactPath = path.join(
    __dirname,
    "../../out",
    `${contractName}.sol/${contractName}.json`
  );

  // Check if file exists
  if (!fs.existsSync(artifactPath)) {
    console.log(`Artifact for ${contractName} not found at ${artifactPath}`);
    console.log("Did you run 'forge build' to compile your contracts?");
    throw new Error(`Artifact not found: ${artifactPath}`);
  }

  const artifact = JSON.parse(fs.readFileSync(artifactPath));

  // Add diagnostic logging
  console.log(
    `Loaded ${contractName} artifact with ${artifact.abi.length} ABI entries`
  );
  const functionCount = artifact.abi.filter(
    (item) => item.type === "function"
  ).length;
  console.log(`Functions in ${contractName} ABI: ${functionCount}`);

  const result = {
    abi: artifact.abi,
    bytecode: artifact.bytecode,
  };

  // Store in cache
  artifactCache.set(contractName, result);

  return result;
}

// New function to get function selectors from ABI
function getFunctionSelectorsFromABI(contractName) {
  const { abi } = loadArtifact(contractName);
  const selectors = [];
  const interface = new ethers.Interface(abi);

  console.log(`Getting selectors for ${contractName}:`);

  for (const fragment of abi) {
    if (fragment.type === "function") {
      try {
        const selector = interface.getFunction(fragment.name).selector;
        console.log(`  Function: ${fragment.name}, Selector: ${selector}`);
        selectors.push(selector);
      } catch (error) {
        console.log(
          `  Error getting selector for ${fragment.name}: ${error.message}`
        );
      }
    }
  }

  console.log(`  Total selectors found: ${selectors.length}`);
  return selectors;
}

async function main() {
  // Connect to provider
  let provider;
  let deployer;

  // Check if we're running in a Node.js environment
  if (typeof window === "undefined") {
    // For local development with hardhat/anvil
    provider = new ethers.JsonRpcProvider(
      "https://eth-sepolia.g.alchemy.com/v2/NZ1c4Vu21IOmBWCLeIe2oVMFLgLbfMLs"
    );

    // Use a private key (make sure this is not a real private key if committing code)
    const PRIVATE_KEY = process.env.PRIVATE_KEY;
    if (!PRIVATE_KEY) {
      console.log("⚠️ Please set PRIVATE_KEY environment variable");
      return;
    }
    deployer = new ethers.Wallet(PRIVATE_KEY, provider);
  } else {
    // For browser environment with MetaMask
    provider = new ethers.BrowserProvider(window.ethereum);
    await window.ethereum.request({ method: "eth_requestAccounts" });
    deployer = provider.getSigner();
  }

  console.log(
    "Deploying contracts with the account:",
    await deployer.getAddress()
  );
  console.log(
    "Account balance:",
    ethers.formatEther(await provider.getBalance(deployer.address))
  );

  try {
    // Deploy DiamondCutFacet first (needed for Diamond constructor)
    const DiamondCutFacet = await deployContract(
      "DiamondCutFacet",
      [],
      deployer
    );
    console.log("DiamondCutFacet deployed to:", DiamondCutFacet.target);

    // Deploy the Diamond contract
    const Diamond = await deployContract(
      "Diamond",
      [
        await deployer.getAddress(), // Contract owner
        DiamondCutFacet.target,
      ],
      deployer
    );
    console.log("Diamond deployed to:", Diamond.target);

    // Deploy DiamondInit
    const DiamondInit = await deployContract("DiamondInit", [], deployer);
    console.log("DiamondInit deployed to:", DiamondInit.target);

    // Deploy the rest of the facets
    const DiamondLoupeFacet = await deployContract(
      "DiamondLoupeFacet",
      [],
      deployer
    );
    console.log("DiamondLoupeFacet deployed to:", DiamondLoupeFacet.target);

    const OwnershipFacet = await deployContract("OwnershipFacet", [], deployer);
    console.log("OwnershipFacet deployed to:", OwnershipFacet.target);

    // Deploy AuthUser
    const AuthUser = await deployContract("AuthUser", [], deployer);
    console.log("AuthUser deployed to:", AuthUser.target);

    // Deploy ViewFacet
    const ViewFacet = await deployContract("viewFacet", [], deployer);
    console.log("ViewFacet deployed to:", ViewFacet.target);

    // Deploy CrossChainFacet (needs router address parameter)
    let CrossChainFacet;
    const ccipRouterAddress = process.env.CCIP_ROUTER_ADDRESS;
    const SEPOLIA_CCIP_ROUTER = "0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59";

    if (ccipRouterAddress) {
      CrossChainFacet = await deployContract(
        "CrossChainFacet",
        [ccipRouterAddress],
        deployer
      );
    } else {
      console.log("\nUsing Sepolia CCIP Router address:", SEPOLIA_CCIP_ROUTER);
      try {
        CrossChainFacet = await deployContract(
          "CrossChainFacet",
          [SEPOLIA_CCIP_ROUTER],
          deployer
        );
      } catch (error) {
        console.log("Error deploying CrossChainFacet, skipping this facet.");
        console.log("Error details:", error.message);
        CrossChainFacet = null;
      }
    }

    if (CrossChainFacet) {
      console.log("CrossChainFacet deployed to:", CrossChainFacet.target);
    }

    // Deploy AutomationLoan
    const AutomationLoan = await deployContract(
      "AutomationLoan",
      [
        AuthUser.target, // _nftContract - The AuthUser acts as the NFT contract
        AuthUser.target, // _userAccountNFT - Also using AuthUser for user accounts
        ViewFacet.target, // _viewFacet
      ],
      deployer
    );
    console.log("AutomationLoan deployed to:", AutomationLoan.target);

    // Process facets and check for selectors
    const facetsToAdd = [
      {
        name: "DiamondLoupeFacet",
        contract: DiamondLoupeFacet,
        contractName: "DiamondLoupeFacet",
      },
      {
        name: "OwnershipFacet",
        contract: OwnershipFacet,
        contractName: "OwnershipFacet",
      },
      { name: "AuthUser", contract: AuthUser, contractName: "AuthUser" },
      { name: "ViewFacet", contract: ViewFacet, contractName: "viewFacet" },
      {
        name: "AutomationLoan",
        contract: AutomationLoan,
        contractName: "AutomationLoan",
      },
    ];

    // Add CrossChainFacet if it was deployed successfully
    if (CrossChainFacet) {
      facetsToAdd.push({
        name: "CrossChainFacet",
        contract: CrossChainFacet,
        contractName: "CrossChainFacet",
      });
    }

    // Check for duplicate selectors across all facets
    const allSelectors = new Map();
    const facetCuts = [];

    for (const facet of facetsToAdd) {
      // Use our new function to get selectors directly from ABI
      const selectors = getFunctionSelectorsFromABI(facet.contractName);

      // Only add facets that have selectors
      if (selectors.length > 0) {
        // Check for duplicates
        const duplicates = [];
        for (const selector of selectors) {
          if (allSelectors.has(selector)) {
            duplicates.push({
              selector,
              existingFacet: allSelectors.get(selector),
            });
          } else {
            allSelectors.set(selector, facet.name);
          }
        }

        // Log any duplicates found
        if (duplicates.length > 0) {
          console.log(
            `⚠️ WARNING: Found duplicate selectors in ${facet.name}:`
          );
          for (const dup of duplicates) {
            console.log(
              `  ${dup.selector} is already registered in ${dup.existingFacet}`
            );
          }

          // Remove duplicates from this facet's selectors
          const uniqueSelectors = selectors.filter(
            (selector) => !duplicates.some((dup) => dup.selector === selector)
          );

          if (uniqueSelectors.length > 0) {
            facetCuts.push({
              facetAddress: facet.contract.target,
              action: 0, // Add
              functionSelectors: uniqueSelectors,
            });
            console.log(
              `Added ${facet.name} with ${uniqueSelectors.length} unique selectors`
            );
          } else {
            console.log(
              `Skipping ${facet.name} - all selectors are duplicates`
            );
          }
        } else {
          // No duplicates, add all selectors
          facetCuts.push({
            facetAddress: facet.contract.target,
            action: 0, // Add
            functionSelectors: selectors,
          });
          console.log(`Added ${facet.name} with ${selectors.length} selectors`);
        }
      } else {
        console.log(`Skipping ${facet.name} because it has no selectors`);
      }
    }

    // Check if we have any facets to add
    if (facetCuts.length === 0) {
      console.log("⚠️ Warning: No facets to add! Diamond cut will fail.");
      console.log("Make sure your contracts have public/external functions.");
      return;
    }

    // Create a Diamond contract interface with the DiamondCutFacet ABI
    const diamondCutFacet = new ethers.Contract(
      Diamond.target,
      loadArtifact("DiamondCutFacet").abi,
      deployer
    );

    // Prepare the initialization call
    const initCalldata = DiamondInit.interface.encodeFunctionData("init", []);

    // Call diamondCut to add facets
    console.log(`Calling diamondCut to add ${facetCuts.length} facets...`);
    const tx = await diamondCutFacet.diamondCut(
      facetCuts,
      DiamondInit.target,
      initCalldata
    );

    console.log("Diamond cut transaction:", tx.hash);
    const receipt = await tx.wait();
    console.log("Diamond cut completed! Gas used:", receipt.gasUsed.toString());

    // Summary of all deployed contracts
    console.log("\n--- DEPLOYMENT SUMMARY ---");
    console.log("Diamond:", Diamond.target);
    console.log("DiamondCutFacet:", DiamondCutFacet.target);
    console.log("DiamondLoupeFacet:", DiamondLoupeFacet.target);
    console.log("DiamondInit:", DiamondInit.target);
    console.log("OwnershipFacet:", OwnershipFacet.target);
    console.log("AuthUser:", AuthUser.target);
    console.log("ViewFacet:", ViewFacet.target);
    if (CrossChainFacet) {
      console.log("CrossChainFacet:", CrossChainFacet.target);
    }
    console.log("AutomationLoan:", AutomationLoan.target);
    console.log("------------------------\n");
  } catch (error) {
    console.error("Error during deployment:", error);
  }
}

// Helper function to deploy a contract
async function deployContract(contractName, args, signer) {
  console.log(`Deploying ${contractName}...`);

  const { abi, bytecode } = loadArtifact(contractName);
  const contractFactory = new ethers.ContractFactory(abi, bytecode, signer);

  const contract = await contractFactory.deploy(...args);
  // Properly wait for the deployment transaction to be confirmed
  const receipt = await contract.deploymentTransaction().wait();

  return contract;
}

// Original function kept for reference but not used
function getFunctionSelectors(contract) {
  const selectors = [];

  // Safety check for contract and interface
  if (!contract || !contract.interface) {
    console.log(`No valid interface found for contract at ${contract?.target}`);
    return selectors;
  }

  const functions = contract.interface.functions || {};
  console.log(`Getting selectors for ${contract.target}:`);

  // Safe way to iterate through functions
  try {
    for (const signature in functions) {
      // Skip constructors, they can't be added to a diamond
      if (signature !== "constructor()") {
        try {
          const selector = contract.interface.getFunction(signature).selector;
          console.log(`  Function: ${signature}, Selector: ${selector}`);
          selectors.push(selector);
        } catch (error) {
          console.log(
            `  Error getting selector for ${signature}: ${error.message}`
          );
        }
      }
    }
  } catch (err) {
    console.log(`Error processing functions: ${err.message}`);
  }

  console.log(`  Total selectors found: ${selectors.length}`);

  // If no selectors were found, log a warning with safe access
  if (selectors.length === 0) {
    console.log(`⚠️ WARNING: No selectors found for ${contract.target}!`);
    try {
      if (functions && Object.keys(functions).length > 0) {
        console.log(`Available functions:`, Object.keys(functions));
      } else {
        console.log(`No functions available in contract interface`);
      }
    } catch (err) {
      console.log(`Could not list functions: ${err.message}`);
    }
  }

  return selectors;
}

// Execute the deployment
if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}

module.exports = {
  deploy: main,
};
