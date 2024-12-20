kyber_plain = [
    "kyber512",
    "kyber768",
    "kyber1024",
]

kyber_hybrid = [
    "x25519_kyber512",
    "x25519_kyber768",
]

kem_trad = [
    "X25519",
]

sign_trad = [
    "ECDSA-SHA2-256",
    "ECDSA-SHA2-384",
]

dilithium_plain = [
    "dilithium2",
    "dilithium3",
]


dilithium_hybrid = [
    "p256_dilithium2",
    "p384_dilithium3",
]


sign_all = sign_trad + dilithium_plain + dilithium_hybrid
kem_all = kyber_plain + kyber_hybrid + kem_trad

arg = " ".join(sign_all + kem_all)

print(f"docker run -it oqs-curl-rpi openssl speed -mr -seconds 10 {arg}")