package recieptservice.com.recieptservice;

// Result of a print job (beginWork ... endWork). Not in the vendor's SDK documents; read from print service 8.3.7 on an H10S.
interface PrintCallback {
    void onPrintResult(int code, String msg);
}
