
#include "mkcert.h"

#include <stdio.h>
#include <stdlib.h>

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <OpenSSL/provider.h>
#include <OpenSSL/rsa.h>
#include <openssl/x509.h>
#include <OpenSSL/rand.h>

static const int NUM_BITS = 2048;
static const int SERIAL = 0;
static const int NUM_YEARS = 20;

void mkcert(X509 **x509p, EVP_PKEY **pkeyp, int bits, int serial, int years) {
    X509* cert = NULL;
    EVP_PKEY_CTX* ctx = NULL;
    EVP_PKEY* pk = NULL;
#if OPENSSL_VERSION_NUMBER >= 0x10100000L
    ASN1_TIME* before = NULL;
    ASN1_TIME* after = NULL;
#endif
    const EVP_MD* digest = NULL;

    if (x509p == NULL || pkeyp == NULL) {
        return;
    }

    // Never expose a partially initialized key pair to the caller.
    *x509p = NULL;
    *pkeyp = NULL;

    cert = X509_new();
    ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_RSA, NULL);
    if (cert == NULL || ctx == NULL) {
        goto cleanup;
    }

    if (EVP_PKEY_keygen_init(ctx) <= 0 ||
        EVP_PKEY_CTX_set_rsa_keygen_bits(ctx, bits) <= 0 ||
        EVP_PKEY_keygen(ctx, &pk) <= 0 ||
        pk == NULL) {
        goto cleanup;
    }

    EVP_PKEY_CTX_free(ctx);
    ctx = NULL;
    
    if (X509_set_version(cert, 2) != 1 ||
        X509_get_serialNumber(cert) == NULL ||
        ASN1_INTEGER_set(X509_get_serialNumber(cert), serial) != 1) {
        goto cleanup;
    }
#if OPENSSL_VERSION_NUMBER < 0x10100000L
    ASN1_TIME* notBefore = X509_get_notBefore(cert);
    ASN1_TIME* notAfter = X509_get_notAfter(cert);
    if (notBefore == NULL || notAfter == NULL ||
        X509_gmtime_adj(notBefore, 0) == NULL ||
        X509_gmtime_adj(notAfter, 60L * 60 * 24 * 365 * years) == NULL) {
        goto cleanup;
    }
#else
    const ASN1_TIME* notBefore = X509_get0_notBefore(cert);
    const ASN1_TIME* notAfter = X509_get0_notAfter(cert);
    if (notBefore == NULL || notAfter == NULL) {
        goto cleanup;
    }

    before = ASN1_STRING_dup(notBefore);
    after = ASN1_STRING_dup(notAfter);
    if (before == NULL || after == NULL ||
        X509_gmtime_adj(before, 0) == NULL ||
        X509_gmtime_adj(after, 60L * 60 * 24 * 365 * years) == NULL ||
        X509_set1_notBefore(cert, before) != 1 ||
        X509_set1_notAfter(cert, after) != 1) {
        goto cleanup;
    }

    ASN1_TIME_free(before);
    ASN1_TIME_free(after);
    before = NULL;
    after = NULL;
#endif

    if (X509_set_pubkey(cert, pk) != 1) {
        goto cleanup;
    }

    X509_NAME* name = X509_get_subject_name(cert);
    digest = EVP_sha256();
    if (name == NULL ||
        digest == NULL ||
        X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC,
                                   (const unsigned char*)"NVIDIA GameStream Client",
                                   -1, -1, 0) != 1 ||
        X509_set_issuer_name(cert, name) != 1 ||
        X509_sign(cert, pk, digest) <= 0) {
        goto cleanup;
    }

    *x509p = cert;
    *pkeyp = pk;
    cert = NULL;
    pk = NULL;

cleanup:
    EVP_PKEY_CTX_free(ctx);
#if OPENSSL_VERSION_NUMBER >= 0x10100000L
    ASN1_TIME_free(before);
    ASN1_TIME_free(after);
#endif
    X509_free(cert);
    EVP_PKEY_free(pk);
}

struct CertKeyPair generateCertKeyPair(void) {
    X509 *x509 = NULL;
    EVP_PKEY *pkey = NULL;
    PKCS12 *p12 = NULL;
    
    mkcert(&x509, &pkey, NUM_BITS, SERIAL, NUM_YEARS);
    if (x509 == NULL || pkey == NULL) {
        printf("Error generating certificate key pair.\n");
        return (CertKeyPair){x509, pkey, NULL};
    }
    
    char* pass = "limelight";
    p12 = PKCS12_create(pass,
                        "GameStream",
                        pkey,
                        x509,
                        NULL,
                        NID_pbe_WithSHA1And3_Key_TripleDES_CBC,
                        -1, // disable certificate encryption
                        2048,
                        -1, // disable the automatic MAC
                        0);
    if (p12 == NULL) {
        printf("Error generating a valid PKCS12 certificate.\n");
        return (CertKeyPair){x509, pkey, NULL};
    }

    // MAC it ourselves with SHA1 since iOS refuses to load anything else.
    if (!PKCS12_set_mac(p12, pass, -1, NULL, 0, 1, EVP_sha1())) {
        printf("Error adding MAC to PKCS12 certificate.\n");
        PKCS12_free(p12);
        p12 = NULL;
    }
    
    return (CertKeyPair){x509, pkey, p12};
}

void freeCertKeyPair(struct CertKeyPair certKeyPair) {
    X509_free(certKeyPair.x509);
    EVP_PKEY_free(certKeyPair.pkey);
    PKCS12_free(certKeyPair.p12);
}
