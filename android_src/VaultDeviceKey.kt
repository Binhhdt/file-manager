package com.fmdemo.file_manager

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal object VaultDeviceKey {
    private const val alias = "fm.vault.config.v1"
    private const val nonceSize = 12
    private val aad = "fm-vault-local-config-v2".toByteArray(Charsets.UTF_8)

    @Synchronized
    private fun key(create: Boolean): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(alias, null)
        if (existing is SecretKey) return existing
        check(create && !store.containsAlias(alias)) { "Vault device key unavailable" }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build())
            generateKey()
        }
    }

    fun seal(input: ByteArray): ByteArray {
        require(input.size in 1..2048)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(create = true))
        cipher.updateAAD(aad)
        check(cipher.iv.size == nonceSize)
        return cipher.iv + cipher.doFinal(input)
    }

    fun unseal(input: ByteArray): ByteArray {
        require(input.size in (nonceSize + 17)..4096)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(create = false), GCMParameterSpec(128, input, 0, nonceSize))
        cipher.updateAAD(aad)
        return cipher.doFinal(input, nonceSize, input.size - nonceSize)
    }
}
