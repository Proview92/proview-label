package recieptservice.com.recieptservice;

interface PSAMCallback {
    void success(in byte[] data);
    void error(int errorCode, String errorMsg);
}
