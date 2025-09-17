test swapping with forge test --match-path test/PrivateCow.t.sol -vv

run anvil
deploy hook via script 
    forge script script/DeployCowHook.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
deploy avs via script
    forge script script/DeployCowAVS.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80


check if hook  contract deployed
cast code 0xce932F8B0C471Cf12a62257b26223Feff2aBC888  --rpc-url http://localhost:8545

run operator 
    cd operator
    pnpm start

run test script simpleswaptest.s.sol
run test script testbatchmatching.s.sol