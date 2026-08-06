# Bitcoin address from private key hex (uncompressed / compressed).
# Dot-source from v3.ps1 and v3-gui.ps1 on Windows PowerShell 5.1+.

if (-not ('KeyHunt.BtcUtil' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Linq;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace KeyHunt
{
    internal static class Secp256k1
    {
        private static readonly BigInteger P = BigInteger.Parse("00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F", System.Globalization.NumberStyles.HexNumber);
        private static readonly BigInteger N = BigInteger.Parse("00FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141", System.Globalization.NumberStyles.HexNumber);
        private static readonly BigInteger Gx = BigInteger.Parse("0079BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798", System.Globalization.NumberStyles.HexNumber);
        private static readonly BigInteger Gy = BigInteger.Parse("00483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8", System.Globalization.NumberStyles.HexNumber);

        private static BigInteger Mod(BigInteger a, BigInteger m)
        {
            var r = a % m;
            return r.Sign < 0 ? r + m : r;
        }

        private static BigInteger ModInv(BigInteger a, BigInteger m)
        {
            return BigInteger.ModPow(Mod(a, m), m - 2, m);
        }

        private static (BigInteger x, BigInteger y) Add((BigInteger x, BigInteger y) p, (BigInteger x, BigInteger y) q)
        {
            if (p.x == BigInteger.Zero && p.y == BigInteger.Zero) return q;
            if (q.x == BigInteger.Zero && q.y == BigInteger.Zero) return p;
            BigInteger lam;
            if (p.x == q.x)
            {
                if (Mod(p.y + q.y, P) == BigInteger.Zero) return (BigInteger.Zero, BigInteger.Zero);
                lam = Mod(3 * p.x * p.x * ModInv(2 * p.y, P), P);
            }
            else
            {
                lam = Mod((q.y - p.y) * ModInv(q.x - p.x, P), P);
            }
            var xr = Mod(lam * lam - p.x - q.x, P);
            var yr = Mod(lam * (p.x - xr) - p.y, P);
            return (xr, yr);
        }

        private static (BigInteger x, BigInteger y) Mul(BigInteger k, (BigInteger x, BigInteger y) p)
        {
            var r = (BigInteger.Zero, BigInteger.Zero);
            var addend = p;
            while (k > 0)
            {
                if ((k & 1) == 1) r = Add(r, addend);
                addend = Add(addend, addend);
                k >>= 1;
            }
            return r;
        }

        public static (byte[] pubUncompressed, byte[] pubCompressed) PubFromPriv(byte[] priv32)
        {
            var d = new BigInteger(priv32.Reverse().Concat(new byte[] { 0 }).ToArray());
            if (d <= 0 || d >= N) throw new ArgumentException("invalid private key");
            var q = Mul(d, (Gx, Gy));
            var xb = q.x.ToByteArray();
            var yb = q.y.ToByteArray();
            Array.Reverse(xb); Array.Reverse(yb);
            var x = Pad32(xb);
            var y = Pad32(yb);
            var uncomp = new byte[65];
            uncomp[0] = 0x04;
            Buffer.BlockCopy(x, 0, uncomp, 1, 32);
            Buffer.BlockCopy(y, 0, uncomp, 33, 32);
            var comp = new byte[33];
            comp[0] = (q.y.IsEven ? (byte)0x02 : (byte)0x03);
            Buffer.BlockCopy(x, 0, comp, 1, 32);
            return (uncomp, comp);
        }

        private static byte[] Pad32(byte[] b)
        {
            if (b.Length == 32) return b;
            if (b.Length > 32) return b.Skip(b.Length - 32).ToArray();
            var o = new byte[32];
            Buffer.BlockCopy(b, 0, o, 32 - b.Length, b.Length);
            return o;
        }
    }

    public static class BtcUtil
    {
        private static byte[] Hash160(byte[] data)
        {
            using (var sha = SHA256.Create())
            {
                var h = sha.ComputeHash(data);
                using (var ripe = RIPEMD160.Create())
                {
                    return ripe.ComputeHash(h);
                }
            }
        }

        private static string Base58Check(byte[] payload)
        {
            using (var sha = SHA256.Create())
            {
                var h1 = sha.ComputeHash(payload);
                var h2 = sha.ComputeHash(h1);
                var data = payload.Concat(h2.Take(4)).ToArray();
                const string alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
                var intData = new BigInteger(data.Reverse().Concat(new byte[] { 0 }).ToArray());
                var sb = new StringBuilder();
                while (intData > 0)
                {
                    intData = BigInteger.DivRem(intData, 58, out var rem);
                    sb.Insert(0, alphabet[(int)rem]);
                }
                foreach (var b in data)
                {
                    if (b == 0) sb.Insert(0, '1');
                    else break;
                }
                return sb.ToString();
            }
        }

        public static string AddressFromPrivHex(string hex, bool compressed)
        {
            hex = (hex ?? "").Trim().Replace("0x", "").Replace("0X", "");
            if (hex.Length == 0) return "";
            if (hex.Length % 2 == 1) hex = "0" + hex;
            var priv = Enumerable.Range(0, hex.Length / 2)
                .Select(i => Convert.ToByte(hex.Substring(i * 2, 2), 16)).ToArray();
            if (priv.Length < 32)
            {
                var p32 = new byte[32];
                Buffer.BlockCopy(priv, 0, p32, 32 - priv.Length, priv.Length);
                priv = p32;
            }
            else if (priv.Length > 32)
            {
                priv = priv.Skip(priv.Length - 32).ToArray();
            }
            var pubs = Secp256k1.PubFromPriv(priv);
            var pub = compressed ? pubs.pubCompressed : pubs.pubUncompressed;
            var h160 = Hash160(pub);
            var payload = new byte[] { 0x00 }.Concat(h160).ToArray();
            return Base58Check(payload);
        }
    }
}
'@
}

function Get-BtcAddressFromPrivHex {
    param(
        [Parameter(Mandatory)][string]$PrivHex,
        [bool]$Compressed = $false
    )
    try {
        return [KeyHunt.BtcUtil]::AddressFromPrivHex($PrivHex, $Compressed)
    }
    catch {
        return ""
    }
}
