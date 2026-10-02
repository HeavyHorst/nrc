package client

import (
	"math"
	"testing"

	"hegel.dev/go/hegel"
)

func TestClientRandomStreamsAreDeterministicAndIndependent(t *testing.T) {
	hegel.Test(t, func(ht *hegel.T) {
		seed := hegel.Draw(ht, hegel.Integers[int64](math.MinInt64, math.MaxInt64))
		steps := int(hegel.Draw(ht, hegel.Integers[uint8](1, 255)))
		interleavedDraws := int(hegel.Draw(ht, hegel.Integers[uint8](0, 255)))

		first := NewClient(1, ClientConfig{RandomSeed: seed})
		interleaved := NewClient(2, ClientConfig{RandomSeed: seed + 1})
		reference := NewClient(3, ClientConfig{RandomSeed: seed})

		for i := 0; i < steps; i++ {
			for j := 0; j < interleavedDraws; j++ {
				_ = interleaved.rng.Uint64()
			}
			got := first.rng.Uint64()
			want := reference.rng.Uint64()
			if got != want {
				ht.Fatalf("random stream diverged at step %d: got %d, want %d", i, got, want)
			}
		}
	})
}
