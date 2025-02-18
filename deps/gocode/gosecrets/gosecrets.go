// @author Couchbase <info@couchbase.com>
// @copyright 2016-Present Couchbase, Inc.
//
// Use of this software is governed by the Business Source License included in
// the file licenses/BSL-Couchbase.txt.  As of the Change Date specified in that
// file, in accordance with the Business Source License, use of this software
// will be governed by the Apache License, Version 2.0, included in the file
// licenses/APL2.txt.
package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/sha1"
	"crypto/sha512"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime/debug"

	"golang.org/x/crypto/pbkdf2"

	"encoding/base64"
	"strings"

	"github.com/couchbase/ns_server/deps/gocode/gocbutils"
)

const keySize = 32
const nIterations = 4096

var hmacFun = sha1.New

var salt = [8]byte{20, 183, 239, 38, 44, 214, 22, 141}

type encryptionService struct {
	initialized    bool
	reader         *bufio.Reader
	configPath     string
	config         *Config
	encryptionKeys secretIface
}

var ErrKeysDoNotExist = errors.New("keys do not exist")
var ErrWrongPassword = errors.New("wrong password")

type secretIface interface {
	read() error
	remove() error
	changePassword([]byte, map[string]interface{}) error
	getPasswordState() string
	getSecret() *secret
	setSecret(*secret) error
	getStorageId() string
	sameSettings(interface{}) bool
}

type secret struct {
	key       []byte // secret itself
	backupKey []byte // backup secret (used for decryption during rotation)
}

type keysInFile struct {
	filePath string
	secret
}

type keysInEncryptedFile struct {
	passwordSource    string // implicitly used by sameSettings (deepEqual)
	lockkey           []byte // derived from password
	isDefaultPassword bool   // true if the password is default (empty)
	keysInFile
}

type keysViaScript struct {
	writeCmd     string
	readCmd      string
	deleteCmd    string
	cmdTimeoutMs int
	secret
}

type EncryptionServiceSettings struct {
	KeyStorageType     string                 `json:"keyStorageType"`
	KeyStorageSettings map[string]interface{} `json:"keyStorageSettings"`
}

type Config struct {
	EncryptionSettings EncryptionServiceSettings `json:"encryptionService"`
	StoredKeyConfigs   []storedKeyConfig         `json:"storedKeys"`
}

func main() {
	defer func() {
		if err := recover(); err != nil {
			log_dbg("panic occurred: %v\n%s", err, string(debug.Stack()))
			panic(err)
		}
	}()

	gocbutils.LimitCPUThreads()

	var configPath string

	flag.StringVar(&configPath, "config", "", "path to configuration file")
	flag.Parse()

	config, err := readCfg(configPath)

	if err != nil {
		panic(err.Error())
	}

	s := &encryptionService{
		reader:     bufio.NewReader(os.Stdin),
		configPath: configPath,
		config:     config,
	}

	for {
		s.processCommand()
	}
}

func (s *encryptionService) readCommand() (byte, []byte) {
	var size uint32
	err := binary.Read(s.reader, binary.BigEndian, &size)
	if err == io.EOF {
		// parent died. close normally
		os.Exit(0)
	}
	if err != nil {
		reportReadError(err)
	}
	if size < 1 {
		panic("Command is too short")
	}
	command, err := s.reader.ReadByte()
	if err != nil {
		reportReadError(err)
	}
	if size == 1 {
		return command, nil
	}

	buf := make([]byte, size-1)
	_, err = io.ReadFull(s.reader, buf)
	if err != nil {
		reportReadError(err)
	}
	return command, buf
}

func reportReadError(err error) {
	panic(fmt.Sprintf("Error reading input %v", err))
}

func doReply(data []byte) {
	err := binary.Write(os.Stdout, binary.BigEndian, uint32(len(data)))
	if err != nil {
		panic(fmt.Sprintf("Error writing data %v", err))
	}
	os.Stdout.Write(data)
}

func replySuccessWithData(data []byte) {
	doReply(append([]byte{'S'}, data...))
}

func replySuccess() {
	doReply([]byte{'S'})
}

func replyError(error string) {
	doReply([]byte("E" + error))
}

func encodeKey(key []byte) []byte {
	if key == nil {
		return []byte{0}
	}
	return append([]byte{byte(len(key))}, key...)
}

func combineDataKeys(key1, key2 []byte) []byte {
	return append(encodeKey(key1), encodeKey(key2)...)
}

func (s *encryptionService) processCommand() {
	command, data := s.readCommand()

	switch command {
	case 1:
		s.cmdInit(data)
	case 2:
		s.cmdGetKeyRef()
	case 3:
		s.cmdEncrypt(data)
	case 4:
		s.cmdDecrypt(data)
	case 5:
		s.cmdChangePassword(data)
	case 6:
		s.cmdRotateDataKey()
	case 7:
		s.cmdClearBackupKey(data)
	case 8:
		s.cmdGetState()
	case 9:
		s.cmdReloadConfig(data)
	case 10:
		s.cmdCopySecrets(data)
	case 11:
		s.cmdCleanupSecrets(data)
	case 12:
		s.cmdStoreKey(data)
	case 13:
		s.cmdEncryptWithKey(data)
	case 14:
		s.cmdDecryptWithKey(data)
	case 15:
		s.cmdReadKey(data)
	case 16:
		s.cmdReadKeyFile(data)
	default:
		panic(fmt.Sprintf("Unknown command %v", command))
	}
}

func (s *encryptionService) cmdGetState() {
	replySuccessWithData([]byte(s.encryptionKeys.getPasswordState()))
}

func (s *encryptionService) cmdInit(data []byte) {
	password := decodePass(data)
	var err error
	s.encryptionKeys, err = initEncryptionKeys(s.config, password)
	if err != nil {
		replyError(err.Error())
		return
	}

	err = readOrCreateKeys(s.encryptionKeys)
	if err != nil {
		replyError(err.Error())
		return
	}
	s.initialized = true
	replySuccess()
}

func decodePass(data []byte) []byte {
	var password []byte
	if data[0] == 1 {
		password = data[1:]
	}
	return password
}

func initEncryptionKeys(config *Config, password []byte) (secretIface, error) {
	if config.EncryptionSettings.KeyStorageType == "file" {
		settings := config.EncryptionSettings.KeyStorageSettings
		return initKeysFromFile(settings, password)
	} else if config.EncryptionSettings.KeyStorageType == "script" {
		settings := config.EncryptionSettings.KeyStorageSettings
		return initKeysViaScript(settings)
	}

	return nil, errors.New(fmt.Sprintf(
		"unknown encryption service key storage type: %s",
		config.EncryptionSettings.KeyStorageType))
}

func initKeysViaScript(settings map[string]interface{}) (*keysViaScript, error) {
	readCmd, found := settings["readCmd"].(string)
	if !found {
		return nil, errors.New(
			"readCmd is mandatory for this type of secret")
	}

	writeCmd, found := settings["writeCmd"].(string)
	if !found {
		writeCmd = ""
	}

	deleteCmd, found := settings["deleteCmd"].(string)
	if !found {
		deleteCmd = ""
	}

	timeoutMs, found := settings["cmdTimeoutMs"].(int)
	if !found {
		timeoutMs = 60000
	}

	return &keysViaScript{
		readCmd:      readCmd,
		writeCmd:     writeCmd,
		deleteCmd:    deleteCmd,
		cmdTimeoutMs: timeoutMs,
		secret:       secret{},
	}, nil
}

func initKeysFromFile(settings map[string]interface{},
	password []byte) (secretIface, error) {
	datakeyFile := settings["path"].(string)

	encryptDatakey := (settings["encryptWithPassword"] == true)

	if !encryptDatakey {
		return &keysInFile{filePath: datakeyFile, secret: secret{}}, nil
	}

	passwordSource, passwordToUse, err := initFilePassword(settings, password)
	if err != nil {
		return nil, err
	}

	lockkey := generateLockKey(passwordToUse)
	emptyPass := (len(passwordToUse) == 0)
	return &keysInEncryptedFile{
		passwordSource:    passwordSource,
		lockkey:           lockkey,
		isDefaultPassword: emptyPass,
		keysInFile: keysInFile{
			filePath: datakeyFile,
			secret:   secret{}},
	}, nil
}

func initFilePassword(
	settings map[string]interface{},
	password []byte) (string, []byte, error) {
	passwordSource := settings["passwordSource"].(string)
	var passwordToUse []byte
	if passwordSource == "env" {
		pwdSettings, ok := settings["passwordSettings"].(map[string]interface{})
		if !ok {
			return passwordSource, nil, errors.New(
				"passwordSettings are missing in config")
		}

		envName, found := pwdSettings["envName"].(string)
		if !found {
			return passwordSource, nil, errors.New(
				"envName is missing in config")
		}
		if password != nil {
			passwordToUse = password
		} else {
			passwordToUse = []byte(os.Getenv(envName))
		}
	} else if passwordSource == "script" {
		if password != nil {
			return passwordSource, nil, errors.New(
				"password is not nil")
		}
		pwdSettings, ok := settings["passwordSettings"].(map[string]interface{})
		if !ok {
			return passwordSource, nil, errors.New(
				"passwordSettings are missing in config")
		}
		passwordCmd, found := pwdSettings["passwordCmd"].(string)
		if !found {
			return passwordSource, nil, errors.New(
				"passwordCmd is missing in config")
		}
		cmdTimeoutMs, found := pwdSettings["cmdTimeoutMs"].(int)
		if !found {
			cmdTimeoutMs = 60000
		}
		output, err := callExternalScript(passwordCmd, cmdTimeoutMs)
		if err != nil {
			return passwordSource, nil, err
		}
		passwordToUse = []byte(output)
	} else {
		return passwordSource, nil, errors.New(
			fmt.Sprintf(
				"unknown password source: %s",
				passwordSource))
	}
	return passwordSource, passwordToUse, nil
}

func saveDatakey(datakeyFile string, dataKey, backupDataKey []byte) error {
	data := combineDataKeys(dataKey, backupDataKey)
	datakeyDir := filepath.Dir(datakeyFile)
	err := os.MkdirAll(datakeyDir, 0755)
	if err != nil {
		msg := fmt.Sprintf("failed to create dir for data key \"%s\": %s",
			datakeyDir, err.Error)
		return errors.New(msg)
	}
	err = atomicWriteFile(datakeyFile, data, 0640)
	if err != nil {
		msg := fmt.Sprintf("failed to write datakey file \"%s\": %s",
			datakeyFile, err.Error)
		return errors.New(msg)
	}
	return nil
}

func readDatakey(datakeyFile string) ([]byte, []byte, error) {
	data, err := os.ReadFile(datakeyFile)
	if os.IsNotExist(err) {
		log_dbg("file %s does not exist", datakeyFile)
		return nil, nil, ErrKeysDoNotExist
	} else if err != nil {
		msg := fmt.Sprintf("failed to read datakey file \"%s\": %s",
			datakeyFile, err)
		return nil, nil, errors.New(msg)
	}
	key, data := readField(data)
	backup, _ := readField(data)
	return key, backup, nil
}

func createRandomKey() []byte {
	dataKey := make([]byte, keySize)
	if _, err := io.ReadFull(rand.Reader, dataKey); err != nil {
		panic(err.Error())
	}
	return dataKey
}

func readField(b []byte) ([]byte, []byte) {
	size := b[0]
	return b[1 : size+1], b[size+1:]
}

// same as readField by the size is encoded by 4 byte uint
func readBigField(data []byte) ([]byte, []byte) {
	sizeBin := data[0:4]
	size := binary.BigEndian.Uint32(sizeBin)
	return data[4 : size+4], data[(size + 4):]
}

func (s *encryptionService) cmdGetKeyRef() {
	replySuccessWithData(s.encryptionKeys.getSecret().getRef())
}

func (s *encryptionService) cmdEncrypt(data []byte) {
	if !s.initialized {
		panic("Password was not set")
	}
	dataKey := s.encryptionKeys.getSecret().key
	replySuccessWithData(encrypt(dataKey, data))
}

func (s *encryptionService) cmdDecrypt(data []byte) {
	if !s.initialized {
		panic("Password was not set")
	}

	key := s.encryptionKeys.getSecret().key

	res, mainKeyErr := decrypt(key, data)
	if mainKeyErr == nil {
		replySuccessWithData(res)
		return
	}

	backupKey := s.encryptionKeys.getSecret().backupKey

	if backupKey == nil {
		replyError(
			fmt.Sprintf(
				"Unable to decrypt value using main key: %s",
				mainKeyErr.Error()))
		return
	}

	res, backupKeyErr := decrypt(backupKey, data)
	if backupKeyErr != nil {
		replyError(
			fmt.Sprintf(
				"Unable to decrypt value using main key: '%s' "+
					"and using backup key: '%s'",
				mainKeyErr.Error(),
				backupKeyErr.Error()))
		return
	}
	replySuccessWithData(res)
}

func (s *encryptionService) cmdChangePassword(data []byte) {
	password := decodePass(data)
	if !s.initialized {
		panic("Password was not set")
	}
	err := s.encryptionKeys.changePassword(
		password,
		s.config.EncryptionSettings.KeyStorageSettings)
	if err != nil {
		replyError(err.Error())
		return
	}
	replySuccess()
}

func (s *encryptionService) cmdRotateDataKey() {
	if !s.initialized {
		panic("Password was not set")
	}
	backupKey := s.encryptionKeys.getSecret().backupKey
	if backupKey != nil {
		replyError("Data key rotation is in progress")
		return
	}
	prevkey := s.encryptionKeys.getSecret().key
	newkey := createRandomKey()
	err := saveKeys(s.encryptionKeys, newkey, prevkey)
	if err != nil {
		replyError(err.Error())
		return
	}
	replySuccess()
}

func (s *encryptionService) cmdClearBackupKey(ref []byte) {
	backupKey := s.encryptionKeys.getSecret().backupKey
	if backupKey == nil {
		replySuccess()
		return
	}

	if !bytes.Equal(s.encryptionKeys.getSecret().getRef(), ref) {
		replyError("Key ref mismatch")
		return
	}
	ctx := &storedKeysCtx{
		storedKeyConfigs:           s.config.StoredKeyConfigs,
		encryptionServiceKey:       s.encryptionKeys.getSecret().key,
		backupEncryptionServiceKey: s.encryptionKeys.getSecret().backupKey,
		keysTouched:                map[string]bool{},
	}
	err := reencryptStoredKeys(ctx)
	if err != nil {
		replyError(err.Error())
		return
	}
	key := s.encryptionKeys.getSecret().key
	err = saveKeys(s.encryptionKeys, key, nil)
	if err != nil {
		replyError(err.Error())
		return
	}
	replySuccess()
}

func (s *encryptionService) cmdReloadConfig(data []byte) {
	password := decodePass(data)
	newConfig, err := readCfg(s.configPath)
	if err != nil {
		replyError(err.Error())
		return
	}
	newEncryptionKeys, err := initEncryptionKeys(newConfig, password)
	if err != nil {
		replyError(err.Error())
		return
	}

	err = readOrCreateKeys(newEncryptionKeys)
	if err != nil {
		replyError(err.Error())
		return
	}
	s.encryptionKeys = newEncryptionKeys
	s.config = newConfig
	replySuccess()
}

func (s *encryptionService) cmdCopySecrets(newCfgBytes []byte) {
	newConfig, err := readCfgBytes(newCfgBytes)
	if err != nil {
		replyError(err.Error())
		return
	}
	newEncryptionKeys, err := initEncryptionKeys(newConfig, nil)
	if err != nil {
		replyError(err.Error())
		return
	}
	res, err := copySecret(s.encryptionKeys, newEncryptionKeys)
	if err != nil {
		replyError(err.Error())
		return
	}
	replySuccessWithData([]byte(res))
}

func (s *encryptionService) cmdCleanupSecrets(oldCfgBytes []byte) {
	oldConfig, err := readCfgBytes(oldCfgBytes)
	if err != nil {
		replyError(err.Error())
		return
	}
	oldKeys, err := initEncryptionKeys(oldConfig, nil)
	if err != nil {
		replyError(err.Error())
		return
	}
	// We absolutelly must not remove secrets that are currently in use
	if oldKeys.getStorageId() == s.encryptionKeys.getStorageId() {
		replyError(fmt.Sprintf(
			"Can't remove secret '%s' because it is being used",
			oldKeys.getStorageId()))
		return
	}
	log_dbg("trying to remove secret: %s", oldKeys.getStorageId())
	err = oldKeys.remove()
	if err != nil {
		replyError(err.Error())
		return
	}
	replySuccess()
}

func (s *encryptionService) cmdStoreKey(data []byte) {
	keyKind, data := readBigField(data)
	keyName, data := readBigField(data)
	keyType, data := readBigField(data)
	keyData, data := readBigField(data)
	isKeyDataEncryptedBin, data := readBigField(data)
	encryptionKeyNameBin, data := readBigField(data)
	creationTime, _ := readBigField(data)
	keyKindStr := string(keyKind)
	keyNameStr := string(keyName)
	keyTypeStr := string(keyType)
	encryptionKeyName := string(encryptionKeyNameBin)
	creationTimeStr := string(creationTime)
	isKeyDataEncryptedStr := string(isKeyDataEncryptedBin)
	isKeyDataEncrypted := (isKeyDataEncryptedStr == "true")
	if isKeyDataEncryptedStr != "true" && isKeyDataEncryptedStr != "false" {
		replyError(fmt.Sprintf("invalid isKeyDataEncrypted param: %v", isKeyDataEncryptedBin))
		return
	}
	log_dbg("Received request to store key %s (kind: %s, type: %s, encrypted: %v, encryptionKey: %s) on disk",
		keyNameStr, keyKindStr, keyTypeStr, isKeyDataEncrypted, encryptionKeyName)
	keySettings, err := getStoredKeyConfig(keyKindStr, s.config.StoredKeyConfigs)
	if err != nil {
		replyError(err.Error())
		return
	}
	var keyInfo storedKeyIface
	if keyTypeStr == string(rawAESGCMKey) {
		rawKeyInfo := &rawAesGcmStoredKey{
			Name:              keyNameStr,
			Kind:              keyKindStr,
			EncryptionKeyName: encryptionKeyName,
			CreationTime:      creationTimeStr,
		}
		if isKeyDataEncrypted {
			rawKeyInfo.EncryptedKey = keyData
			rawKeyInfo.EncryptedByKind = keySettings.EncryptByKind
		} else {
			rawKeyInfo.DecryptedKey = keyData
		}
		keyInfo = rawKeyInfo
	} else if keyTypeStr == string(awskmKey) {
		var awsk awsStoredKey
		err = json.Unmarshal(keyData, &awsk)
		if err != nil {
			replyError(fmt.Sprintf("invalid json: %v", keyData))
			return
		}
		awsk.Name = keyNameStr
		awsk.Kind = keyKindStr
		awsk.CreationTime = creationTimeStr
		keyInfo = &awsk
	} else {
		replyError(fmt.Sprintf("unknown type: %s", keyTypeStr))
		return
	}

	ctx := &storedKeysCtx{
		storedKeyConfigs:           s.config.StoredKeyConfigs,
		encryptionServiceKey:       s.encryptionKeys.getSecret().key,
		backupEncryptionServiceKey: s.encryptionKeys.getSecret().backupKey,
		keysTouched:                map[string]bool{},
	}

	if !keyInfo.needRewrite(keySettings) {
		// key is already on disk and encrypted with the correct key
		log_dbg("Key %s is already on disk, will do nothing", keyNameStr)
		replySuccess()
		return
	}

	err = encryptKey(keyInfo, ctx)
	if err != nil {
		replyError(err.Error())
		return
	}

	err = writeKeyToDisk(keyInfo, keySettings)
	if err != nil {
		replyError(err.Error())
		return
	}

	replySuccess()
}

func (s *encryptionService) cmdReadKeyFile(data []byte) {
	keyPath, data := readBigField(data)
	keyPathStr := string(keyPath)
	keyIface, err := readKeyFromFileRaw(keyPathStr)
	if err != nil {
		replyError(err.Error())
		return
	}
	replyReadKey(s, keyIface)
}

func (s *encryptionService) cmdReadKey(data []byte) {
	keyKind, data := readBigField(data)
	keyName, data := readBigField(data)
	keyKindStr := string(keyKind)
	keyNameStr := string(keyName)
	keySettings, err := getStoredKeyConfig(keyKindStr, s.config.StoredKeyConfigs)
	if err != nil {
		replyError(err.Error())
		return
	}
	keyIface, err := readKeyRaw(keySettings, keyNameStr)
	if err != nil {
		replyError(err.Error())
		return
	}
	replyReadKey(s, keyIface)
}

func replyReadKey(s *encryptionService, keyIface storedKeyIface) {
	ctx := &storedKeysCtx{
		storedKeyConfigs:           s.config.StoredKeyConfigs,
		encryptionServiceKey:       s.encryptionKeys.getSecret().key,
		backupEncryptionServiceKey: s.encryptionKeys.getSecret().backupKey,
		keysTouched:                map[string]bool{},
	}
	err := decryptKey(keyIface, ctx)
	if err != nil {
		replyError(err.Error())
		return
	}
	rawKey, ok := keyIface.(*rawAesGcmStoredKey)
	if !ok {
		replyError("key type not supported")
		return
	}
	keyBase64 := base64.StdEncoding.EncodeToString(rawKey.DecryptedKey)
	keyToMarshal := readKeyAesKeyResponse{
		Key:             keyBase64,
		EncryptionKeyId: rawKey.EncryptionKeyName,
		CreationTime:    rawKey.CreationTime,
	}
	keyJson, err := json.Marshal(keyToMarshal)
	if err != nil {
		replyError(fmt.Sprintf("failed to marshal key: %s", err.Error()))
		return
	}
	replyToMarshal := readKeyReply{
		Type: string(rawAESGCMKey),
		Info: keyJson,
	}
	replyJson, err := json.Marshal(replyToMarshal)
	if err != nil {
		replyError(fmt.Sprintf("failed to marshal reply: %s", err.Error()))
		return
	}
	replySuccessWithData(replyJson)
}

func (s *encryptionService) cmdEncryptWithKey(data []byte) {
	toEncrypt, data := readBigField(data)
	keyKindBin, data := readBigField(data)
	keyNameBin, data := readBigField(data)
	keyKind := string(keyKindBin)
	keyName := string(keyNameBin)

	ctx := &storedKeysCtx{
		storedKeyConfigs:           s.config.StoredKeyConfigs,
		encryptionServiceKey:       s.encryptionKeys.getSecret().key,
		backupEncryptionServiceKey: s.encryptionKeys.getSecret().backupKey,
		keysTouched:                map[string]bool{},
	}
	encryptedData, err := encryptWithKey(keyKind, keyName, toEncrypt, ctx)
	if err != nil {
		replyError(err.Error())
		return
	}
	replySuccessWithData(encryptedData)
}

func (s *encryptionService) cmdDecryptWithKey(data []byte) {
	toDecrypt, data := readBigField(data)
	keyKindBin, data := readBigField(data)
	keyNameBin, data := readBigField(data)
	keyKind := string(keyKindBin)
	keyName := string(keyNameBin)

	ctx := &storedKeysCtx{
		storedKeyConfigs:           s.config.StoredKeyConfigs,
		encryptionServiceKey:       s.encryptionKeys.getSecret().key,
		backupEncryptionServiceKey: s.encryptionKeys.getSecret().backupKey,
		keysTouched:                map[string]bool{},
	}
	decryptedData, err := decryptWithKey(keyKind, keyName, toDecrypt, ctx)
	if err != nil {
		replyError(err.Error())
		return
	}
	replySuccessWithData(decryptedData)
}

func generateLockKey(password []byte) []byte {
	return pbkdf2.Key(password, salt[:], nIterations, keySize, hmacFun)
}

func log_dbg(str string, args ...interface{}) {
	doReply([]byte("L" + fmt.Sprintf(str, args...)))
}

// Implementation of secretIface for keysInFile

func (keys *keysInFile) setSecret(s *secret) error {
	err := saveDatakey(keys.filePath, s.key, s.backupKey)
	if err != nil {
		return err
	}
	copySecretStruct(s, &keys.secret)
	return nil
}

func (keys *keysInFile) read() error {
	key, backupKey, err := readDatakey(keys.filePath)
	if err != nil {
		return err
	}
	if len(backupKey) > 0 {
		keys.secret.backupKey = backupKey
	} else {
		keys.secret.backupKey = nil
	}
	keys.secret.key = key
	log_dbg("read encryption keys from '%s' (%d byte main key, "+
		"and %d byte backup key)", keys.filePath, len(key), len(backupKey))
	return nil
}

func (keys *keysInFile) remove() error {
	return os.Remove(keys.filePath)
}

func (keys *keysInFile) changePassword(
	password []byte,
	settings map[string]interface{}) error {
	return errors.New("not supported")
}

func (keys *keysInFile) getPasswordState() string {
	return "password_not_used"
}

func (secret *secret) getRef() []byte {
	res := sha512.Sum512(combineDataKeys(secret.key, secret.backupKey))
	return res[:]
}

func (sec *secret) getSecret() *secret {
	return sec
}

func (keys *keysInFile) getStorageId() string {
	return "file:" + keys.filePath
}

func (keys *keysInFile) sameSettings(param interface{}) bool {
	keys2, ok := param.(*keysInFile)
	if !ok {
		return false
	}
	oldsecret := keys2.secret
	keys2.secret = keys.secret
	defer func() {
		keys2.secret = oldsecret
	}()
	return reflect.DeepEqual(keys, keys2)
}

// Implementation of secretIface for keysInEncryptedFile

func (keys *keysInEncryptedFile) setSecret(s *secret) error {
	newSecret := secret{}
	copySecretStruct(s, &newSecret)
	encryptedKey := encrypt(keys.lockkey, newSecret.key)
	var encryptedBackup []byte
	if newSecret.backupKey == nil {
		encryptedBackup = nil
	} else {
		encryptedBackup = encrypt(keys.lockkey, newSecret.backupKey)
	}
	err := saveDatakey(keys.filePath, encryptedKey, encryptedBackup)
	if err != nil {
		return err
	}
	keys.keysInFile.secret = newSecret
	return nil
}

func (keys *keysInEncryptedFile) read() error {
	encryptedKey, encryptedBackup, err := readDatakey(keys.filePath)
	if err != nil {
		return err
	}

	key, err := decrypt(keys.lockkey, encryptedKey)
	if err != nil {
		return errors.New(fmt.Sprintf("key decrypt failed: %s",
			err.Error()))
	}
	keys.secret.key = key

	if len(encryptedBackup) > 0 {
		backup, err := decrypt(keys.lockkey, encryptedBackup)
		if err != nil {
			return errors.New(fmt.Sprintf("backup key decrypt failed: %s",
				err.Error()))
		}
		keys.secret.backupKey = backup
	} else {
		keys.secret.backupKey = nil
	}

	log_dbg("read encryption keys from '%s' (%d byte main key, "+
		"and %d byte backup key)",
		keys.filePath, len(encryptedKey), len(encryptedBackup))
	return nil
}

func (keys *keysInEncryptedFile) changePassword(
	password []byte,
	settings map[string]interface{}) error {
	_, passwordToUse, err := initFilePassword(settings, password)
	if err != nil {
		return err
	}
	oldLockkey := keys.lockkey
	keys.lockkey = generateLockKey(passwordToUse)
	err = keys.setSecret(keys.getSecret())
	if err != nil {
		keys.lockkey = oldLockkey
		return err
	}
	keys.isDefaultPassword = (len(passwordToUse) == 0)
	return nil
}

func (keys *keysInEncryptedFile) getPasswordState() string {
	if keys.isDefaultPassword {
		return "default"
	}
	return "user_configured"
}

func (keys *keysInEncryptedFile) sameSettings(param interface{}) bool {
	keys2, ok := param.(*keysInEncryptedFile)
	if !ok {
		return false
	}
	oldsecret := keys2.secret
	oldLockkey := keys2.lockkey
	oldIsDefaultPass := keys2.isDefaultPassword
	keys2.secret = keys.secret
	keys2.lockkey = keys.lockkey
	keys2.isDefaultPassword = keys.isDefaultPassword
	defer func() {
		keys2.secret = oldsecret
		keys2.lockkey = oldLockkey
		keys2.isDefaultPassword = oldIsDefaultPass
	}()
	return reflect.DeepEqual(keys, keys2)
}

// Implementation of secretIface for keysViaScript

func (keys *keysViaScript) setSecret(s *secret) error {
	keyBase64 := base64.StdEncoding.EncodeToString(s.getSecret().key)
	backupBase64 := base64.StdEncoding.EncodeToString(s.getSecret().backupKey)
	cmd := strings.Join([]string{keys.writeCmd, keyBase64, backupBase64}, " ")
	_, err := callExternalScript(cmd, keys.cmdTimeoutMs)
	if err != nil {
		return err
	}
	copySecretStruct(s, &keys.secret)
	return nil
}

func (keys *keysViaScript) read() error {
	res, err := callExternalScript(keys.readCmd, keys.cmdTimeoutMs)
	if err != nil {
		return err
	}
	keysTokens := strings.Fields(res)
	var backup []byte
	if len(keysTokens) == 2 {
		backup, err = base64.StdEncoding.DecodeString(keysTokens[1])
		if err != nil {
			return errors.New(
				fmt.Sprintf(
					"Failed to decode backup key "+
						"(expected to be base64 encoded): %s",
					err.Error()))
		}
	} else if len(keysTokens) == 1 {
		backup = nil
	} else if len(keysTokens) == 0 {
		return ErrKeysDoNotExist
	} else {
		return errors.New(
			fmt.Sprintf(
				"Unexpected number of keys (%v) returned by %s",
				len(keysTokens), keys.readCmd))
	}
	key, err := base64.StdEncoding.DecodeString(keysTokens[0])
	if err != nil {
		return errors.New(
			fmt.Sprintf(
				"Failed to decode key (expected to be base64 encoded): %s",
				err.Error()))
	}
	keys.secret.key = key
	keys.secret.backupKey = backup
	log_dbg("read keys via script '%s'", keys.readCmd)
	return nil
}

func (keys *keysViaScript) remove() error {
	_, err := callExternalScript(keys.deleteCmd, keys.cmdTimeoutMs)
	if err != nil {
		return err
	}
	return nil
}

func (keys *keysViaScript) changePassword(
	password []byte,
	settings map[string]interface{}) error {
	return errors.New("not supported")
}

func (keys *keysViaScript) getPasswordState() string {
	return "password_not_used"
}

func (keys *keysViaScript) getStorageId() string {
	return "script:" + keys.writeCmd
}

func (keys *keysViaScript) sameSettings(param interface{}) bool {
	keys2, ok := param.(*keysViaScript)
	if !ok {
		return false
	}
	oldsecret := keys2.secret
	keys2.secret = keys.secret
	defer func() {
		keys2.secret = oldsecret
	}()
	return reflect.DeepEqual(keys, keys2)
}

// Other functions:

func copySecret(from, to secretIface) (string, error) {
	log_dbg("Trying to copy a secret\nOld cfg type: %v\nNew cfg type: %v",
		reflect.TypeOf(from), reflect.TypeOf(to))

	if from.sameSettings(to) {
		log_dbg("same secret configs, nothing to do")
		return "same", nil
	}

	// Here we are trying to make sure we are not corrupting existing secrets
	// by creating secrets copy for new config.
	// For example, if new and old config use the same file on disk, we might
	// corrupt old secret file by writing to the same file using new config.
	err := to.read()

	if err != nil {
		if !errors.Is(err, ErrKeysDoNotExist) {
			// We can't continue even if it is caused by a different password
			// because the copy will basically change the password for
			// the secret then, and rollback will not work in case of a problem
			return "", errors.New(
				fmt.Sprintf(
					"Secret already exists but it can't be read (%s)",
					err.Error()))
		}
		log_dbg("New secret doesn't exist")
	} else {
		// Even if new config uses the same storage for this secret,
		// it should be safe to overwrite it using new config
		// because it should not really change the file (but we still
		// want to do the writing, because we want to test that it
		// works)
		secretsMatch := bytes.Equal(from.getSecret().key, to.getSecret().key) &&
			bytes.Equal(from.getSecret().backupKey, to.getSecret().backupKey)
		if !secretsMatch {
			log_dbg(
				"New secret already exists and it doesn't " +
					"match the secret that is in use")
			oldStorage := from.getStorageId()
			newStorage := to.getStorageId()
			if oldStorage == newStorage {
				return "", errors.New(
					fmt.Sprintf(
						"Can't use exactly same storage for secret "+
							"(old storage: %s, new storage: %s)",
						oldStorage, newStorage))
			}
			// that's ok, new and old configs use different storages
			// for secrets, so we will not overwrite existing secret
			// if we save new secret here
		} else {
			log_dbg("New secret already exists and it matches" +
				"the secret that is in use")
		}
	}
	err = to.setSecret(from.getSecret())
	if err != nil {
		return "", err
	}
	// just making sure it is readable
	err = to.read()
	if err != nil {
		log_dbg("Failed to read the secret after writing: %s", err.Error())
		return "", err
	}
	return "copied", nil
}

func saveKeys(keys secretIface, key, backup []byte) error {
	newSecret := secret{key: key, backupKey: backup}
	return keys.setSecret(&newSecret)
}

// Note: keys must be a pointer to a struct
func readOrCreateKeys(keys secretIface) error {
	err := keys.read()
	if errors.Is(err, ErrKeysDoNotExist) {
		log_dbg("Generating secret")
		key := createRandomKey()
		return saveKeys(keys, key, nil)
	}
	return err
}

func readCfg(configPath string) (*Config, error) {
	configBytes, err := os.ReadFile(configPath)

	if err != nil {
		return nil, errors.New(
			fmt.Sprintf("failed to read config file (\"%s\"): %s",
				configPath, err))
	}
	return readCfgBytes(configBytes)
}

func readCfgBytes(configBytes []byte) (*Config, error) {
	log_dbg("parsing config: \n%s", string(configBytes))
	var config Config
	err := json.Unmarshal(configBytes, &config)
	if err != nil {
		return nil, errors.New(
			fmt.Sprintf(
				"failed to parse config file: %s\n%s",
				err, configBytes))
	}

	return &config, nil
}

func copySecretStruct(from *secret, to *secret) {
	to.key = make([]byte, len(from.key))
	copy(to.key, from.key)
	if from.backupKey == nil {
		to.backupKey = nil
	} else {
		to.backupKey = make([]byte, len(from.backupKey))
		copy(to.backupKey, from.backupKey)
	}
}
