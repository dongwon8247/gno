package std

import (
	"std"
	"testing"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/testutils"
)

var (
	denoms avl.Tree // id -> *minter
)

func Mint(addr std.Address, denom string, amount int64) {
	caller := std.GetOrigCaller()
	if denoms.Has(denom) {
		data, _ := denoms.Get(denom)
		minter := data.(std.Address)
		if minter != caller {
			panic("not minter")
		}
	} else {
		denoms.Set(denom, caller)
	}

	issuer := std.GetBanker(std.BankerTypeRealmIssue)
	issuer.IssueCoin(addr, denom, amount)
}

func TestMint(t *testing.T) {
	who := testutils.TestAddress("who")
	issuer := std.GetBanker(std.BankerTypeRealmIssue)

	shouldEQ(t, len(issuer.GetCoins(who)), 0)

	issuer.IssueCoin(who, "ugnot", 123)
	shouldEQ(t, len(issuer.GetCoins(who)), 1)
	shouldEQ(t, issuer.GetCoins(who)[0].Amount, 123)
	shouldEQ(t, issuer.GetCoins(who)[0].Denom, "realm/dde02d16adbf1a4ff70e273c871d6de322b30075a0a8a0e7b6cd5a27f5189922")
}

func shouldEQ(t *testing.T, got, wanted interface{}) {
	if got != wanted {
		t.Errorf("got %v(%T), wanted %v(%T)", got, got, wanted, wanted)
	}
}
