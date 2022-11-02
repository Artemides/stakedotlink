export const config = {
  PoolOwners: {
    derivativeTokenName: 'Staked LPL',
    derivativeTokenSymbol: 'stLPL',
  },
  StakingAllowance: {
    name: 'Staking Allowance',
    symbol: 'STA',
  },
  LendingPool: {
    derivativeTokenName: 'Lent STA',
    derivativeTokenSymbol: 'lSTA',
    rateConstantA: 10,
    rateConstantB: 500,
    rateConstantC: 6,
    rateConstantD: 12,
    rateConstantE: 20,
  },

  LINK_WrappedSDToken: {
    name: 'Wrapped stLINK',
    symbol: 'wstLINK',
  },
  LINK_WrappedBorrowedSDToken: {
    name: 'Wrapped bstLINK',
    symbol: 'wbstLINK',
  },
  LINK_StakingPool: {
    derivativeTokenName: 'Staked LINK',
    derivativeTokenSymbol: 'stLINK',
    fees: [],
    ownersFeeBasisPoints: 1000,
  },
  LINK_BorrowingPool: {
    derivativeTokenName: 'Borrowed stLINK',
    derivativeTokenSymbol: 'bstLINK',
  },

  ETH_WrappedSDToken: {
    name: 'Wrapped stETH',
    symbol: 'wstETH',
  },
  ETH_StakingPool: {
    derivativeTokenName: 'Staked ETH',
    derivativeTokenSymbol: 'stETH',
    fees: [],
    ownersFeeBasisPoints: 1000,
  },
}
