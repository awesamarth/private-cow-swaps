test swapping with forge test --match-path test/PrivateCow.t.sol -vv

run anvil
deploy hook via script 
    forge script script/DeployCowHook.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
deploy avs via script
    forge script script/DeployCowAVS.s.sol --rpc-url http://localhost:8545 --broadcast --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80


check if hook  contract deployed
cast code 0x11cAE71f4e583D9eA40c10ffD9023bd576d30888  --rpc-url http://localhost:8545

run operator 
    cd operator
    pnpm start

run test script simpleswaptest.s.sol
    
run test script testbatchmatching.s.sol