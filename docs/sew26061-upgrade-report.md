# SEW26061-00：Windows 11 更新調查與驗證紀錄

本報告記錄從 **SEW25091-00** 移除舊版、安裝 **SEW26061-00** 的調查與驗證。一般使用者請先看 [README](../README.md)；先前 SEW25091 的成功安裝、PowerShell 與 SQL 修復證據，保留在 [Windows 11 安裝問題報告](windows11-installation-report.md)。

**目前狀態：新版媒體已核對；依使用者不保留本機舊資料的要求停止未完成備份後，已完成舊版原廠卸載及卸載後重啟。兩個 SQL 引擎仍在執行；新版安裝尚未開始，安裝後驗收尚未完成。** 使用者其後將交付範圍改為「一鍵準備缺少的元件，原廠主程式自行安裝」。新版前置入口的隔離測試與本機唯讀工作流程檢查已通過；缺少元件的全新安裝與 GUI/UAC 全流程未重新實機驗證。舊版成功截圖不作為新版成功證據。

## 現行入口的範圍

主要入口為 `Install-Prerequisites.cmd`，`Install-MUT.cmd` 改為相同前置流程的相容入口，主控腳本為 `scripts/Prepare-MutPrerequisites.ps1`。執行前置流程不需要原廠 ZIP；保留專案所附的 `ps2DLC.zip` 及完整 `scripts` 資料夾即可。

| 處理項目 | 現行範圍 |
| --- | --- |
| Windows 元件 | 檢查 NetFx3 與 Microsoft 暫時補充元件，僅處理缺少項目 |
| 核驗 | 核對所需 32／64 位元組件與實際執行狀態，恢復處理前的執行原則 |
| 已知 SQL 權限問題 | 只有原廠安裝已關閉、指定 SQL 引擎停止，且身分與 MDAC `0x5／0x90` 錯誤證據符合時，才套用限定 ACL 修復 |
| 原廠主程式 | 由使用者完整解壓、以管理員身分執行 `MUT3_Install.bat` |
| 其他系統操作 | 前置入口不啟動原廠安裝／解除安裝，不安裝或清理 SQL，不啟動 SQL 服務，也不執行備份 |

前置狀態存於 `C:\MUT-Install\prerequisite-state.json`，與先前整合流程的進度分開；本次日誌與 `result.json`／`report.json` 位於 `C:\MUT-Install\prerequisite-logs\<日期時間-唯一識別碼>`。需要底層修復時，報告另指向 `repair-logs` 或 `sql-acl-repair-logs`。

成功視窗的「前置元件準備完成」只代表前置核驗通過，不代表 M.U.T. 主程式安裝完成。要求重啟時，重新啟動後再執行同一入口。第 3、7 節保留先前完整升級流程的調查與測試歷史，**它們不是目前前置入口會自動執行的功能**。

## 1. 新版媒體已確認的內容

| 項目 | 調查結果 |
| --- | --- |
| 調查日期 | 2026-10-11，Asia/Taipei |
| 來源 | 使用者提供的 CMC 更新主檔分享連結 |
| 壓縮檔名稱 | `SEW26061-00.zip` |
| 檔案大小 | `1,856,637,670` bytes |
| ZIP SHA-256 | `A4BEA8E3795B1DEB4F966D8C8A70ED2FDB58607522E7624AC826FFF8738D03A8` |
| 本機解壓位置 | `C:\MUT-Install\SEW26061-00` |
| 媒體結構 | `917` 個項目：`793` 個檔案、`124` 個目錄；解壓檔案總大小 `2,064,062,130` bytes |
| 原廠安裝入口 | `MUT3_Install.bat` |
| SE 目標版本 | `SEW26061-00` |
| 傳統版目標版本 | `PRG23061-03`，本次 SE 更新不代表傳統版版本號同步改變 |
| SQL 相依元件 | 仍為原廠 SQL Server 2014 Express SP1 x86，`12.0.4100.1` |
| 原廠 SQL 執行個體 | `MUT3`、`CAESARCOMPDB` |

檔案雜湊用於識別本次實際取得的安裝包；它不等於供應商數位簽章。未將原廠 ZIP、原廠 PDF、Google 帳號資訊或原始機器紀錄加入公開專案。

SE 版本已從 `INSTALL/SE/SRC/MUT3_SE.zip` 內的 `MUT3_SE/System/Version.xml` 核對；傳統版版本來自 `Tools/Checker/ini/MUT3_Checker.ini`。基本傳統版 CAB 與舊包相同，但 `RESOURCES/SRC/MUT3.cab` 不同，因此只說明傳統版版本號未變，不宣稱全部檔案皆未改變。

原廠入口、解除安裝流程、SQL 相關檔案與 SE 更新批次已和 SEW25091 比較。三份 SQL 安裝 EXE 與舊版一致，SHA-256 均為 `9782EF313CEEE7257D45785CFEE6F59F57D3FCDDBD603D2AD58B73694E9B7D46`；四個資料庫安裝器的 `setup.inx` 也與舊版相同。SQL 元件沒有因 SE 版本更新而改成支援 Windows 11 的新版 SQL；既有 SQL 權限修復仍須以實際錯誤日誌為依據，不能因版本號相近就直接套用。

## 2. 為什麼這次先移除 SEW25091

新版 `@Region/PRG/BAT/SE_G.BAT` 列出的直接更新來源為 **SEW25121、SEW26031**。本機升級前使用的 **SEW25091 不在這次直接更新範圍**。

隨包的 `M.U.T.-3_Update_Manual_For_Download_Edition(SEW26061).pdf` FAQ 第 1 項說明：既有版本不是更新對象時，需先解除安裝，再使用最新安裝資料重新安裝。先前的整合方案因此設計為「完成備份 → 原廠解除安裝 → 實際重啟 → 新版完整安裝」。本機使用者在備份執行途中明確要求不保留舊資料，之後已另行使用原廠入口卸載；未改寫版本登錄值，也未用未完成備份繞過原升級檢查。現行前置入口不執行這段卸載與重裝流程。

原廠解除安裝會影響資料。舊版的 `UNINSTALL1.INI`／`UNINSTALL2.INI` 包含資料庫與診斷軟體移除；`Del_SE.bat` 會刪除整個 `C:\MUTSW_SE`，也會刪除兩個公用桌面捷徑。這不是保證保留資料的原地更新。

卸載後是否仍留下 SQL 引擎，必須重新檢查。先前 SEW25091 的失敗安裝曾留下 SQL 服務與共用元件；這不表示此次健康安裝也需要相同清理。既有 [失敗 SQL 清理程式](../scripts/Remove-FailedMutSqlInstances.ps1) 只適用於它能辨識的失敗條件，不能拿來直接刪除有效資料庫。

## 3. 先前整合方案的備份保護與本機取消紀錄

先前整合方案加入 [Backup-MutUpgrade.ps1](../scripts/Backup-MutUpgrade.ps1)，只處理已核對的 `PRG23061-03`／`SEW25091-00` 舊版。以下為該方案的設計及實際執行紀錄；**現行前置入口不呼叫此備份流程**。當時的備份目的地為本機的：

```text
C:\MUT-Install\upgrade-backups\<日期時間-唯一識別碼>\
```

它會先確認沒有 MUT 程式或安裝程序正在執行，再核對 SQL 來源、服務帳號、版本、資料庫清單及實體檔案路徑。未知版本、未知資料庫或 reparse point 會停止；不為了繼續而刪除未知內容。

| 備份內容 | 作法與通過條件 |
| --- | --- |
| MUT3 的 42 個非系統資料庫 | 分別建立 `COPY_ONLY`、`CHECKSUM` 備份 |
| CAESARCOMPDB 的 2 個非系統資料庫 | 同樣備份 `CAESARCOMPDB2`、`CFFDB` |
| SQL 備份驗證 | 每份執行 `RESTORE VERIFYONLY`、核對備份標頭，再複製並比對 SHA-256 |
| `C:\MUTSW`、`C:\MUTSW_SE` | 複製非 SQL 資料庫檔案與空目錄，比對來源及備份雜湊；正在使用的 MDF／LDF 由 SQL `.bak` 保護 |
| 設定與證據 | 保存 MMC 登錄、兩個捷徑、InstLog、一鍵入口狀態及必要環境紀錄 |
| 完成紀錄 | 只有全部步驟成功，`manifest.json` 才標示 `Complete` |

SQL `.bak` 先產生在各執行個體既有的 `Backup` 目錄，驗證後複製至統一備份目錄；原本的暫存 `.bak` 會保留。失敗時也保留已產生檔案，不能把未完成的備份當成可繼續卸載的依據。

需要特別保存的 SE 使用者資料包括 `Temp\RecData` 的行車記錄／Data List 資料，以及 `CdgData` 的 ECU coding 檔案。即使這些資料夾在本次檢查時為空，仍會保留整棵程式目錄內的其他設定與檔案。

`COPY_ONLY` 不重設既有差異備份基準；`RESTORE VERIFYONLY` 檢查備份完整性與可讀性，但不等於已實際還原或通過完整資料庫結構檢查。這份備份也不是 Windows 系統映像。[Microsoft COPY_ONLY 說明](https://learn.microsoft.com/en-us/sql/relational-databases/backup-restore/copy-only-backups-sql-server)、[VERIFYONLY 說明](https://learn.microsoft.com/en-us/sql/t-sql/statements/restore-statements-verifyonly-transact-sql)

### 本機實際執行結果

2026-10-11 22:16（Asia/Taipei）開始執行備份；在檔案複製尚未完成時，使用者明確表示「不用備份目前的檔案都沒有要實際使用」。依此要求，於 22:32 停止本次助手及其備份子程序，保留已產生的部分檔案。

- 備份**未取得 `Complete` manifest**，也沒有完成 manifest 的雜湊紀錄；部分 SQL 備份與已複製檔案不代表完整備份可用。
- 升級進度改為 `ReviewRequired`，原廠卸載的開始欄位仍為空；停止備份時尚未移除舊版，也未停止 SQL 服務。
- 沒有刪除部分備份、偽造完成紀錄，或將此例外加入先前的整合升級流程。
- Windows 當時有待重啟的檔案操作。使用者自行重新啟動，已核對本輪開機時間為 **2026-10-11 22:36:52（Asia/Taipei）**。這是卸載前重啟，不算作卸載後或新版安裝後的重啟驗收。

重新啟動後，於 2026-10-11 22:47（Asia/Taipei）啟動舊版原廠 `UNINST.BAT`，使用者在解除安裝確認框按「是」。原廠卸載已完成，並已再次重新啟動 Windows；核對實際開機時間為 **2026-10-11 22:52:27.5（Asia/Taipei）**。

卸載後的盤點確認：`C:\MUTSW`、`C:\MUTSW_SE`、`APP00` 安裝登錄、M.U.T. 應用程式安裝項目與兩個桌面捷徑均已移除，待重啟旗標已清除。`MSSQL$MUT3`、`MSSQL$CAESARCOMPDB` 兩個 SQL 引擎服務仍為 `Running`／自動啟動，服務帳號仍是 `NETWORKSERVICE`，執行檔路徑與卸載前相同。此結果只確認原廠保留 SQL 引擎，不代表新版資料庫已安裝或通過驗收。

本輪不保留舊資料的新版完整安裝尚未開始；其後曾準備的新版安裝前檢查未完成 UAC，已取消，沒有啟動新版原廠主程式。未將只適用於失敗安裝的 SQL 清理程式用在這兩個保留的引擎。**即使後續手動重裝成功，也不能據此宣稱先前完整備份升級流程已完成實機驗證。**

## 4. 新版的 PowerShell 2.0 處理有何不同

新版仍可能在安裝時詢問是否只安裝 SE。原廠手冊說明：選「是」會只裝 SE；需要傳統版與 SE 時，應先處理相關元件，再重新執行完整安裝。

`NEW.BAT` 新增磁碟區段與 Registry64 `ApplicationBase` 等前置檢查；`PS20_Check` 的分支提供 SE 單獨安裝或取消。另有備用的 PowerShell 安裝批次，但未在已讀取的主安裝批次鏈找到呼叫，不能假設原廠入口已自動補齊全部前置元件。

這次媒體新增兩組原廠工具：

| 路徑 | 靜態檢查結果 |
| --- | --- |
| `Tools\PowerShell2\PowerShell_Install.bat` | 呼叫同一資料夾內的 Microsoft `loadGAC.ps1`；隨附手冊要求先取得 `ps2DLC.zip`，將批次放到載入器旁執行 |
| `Tools\Delete_PowerShell2\Del_PS_2.bat` | 核對 Windows build 與指定登錄值後，呼叫 `ps\Uninstall-ps2DLC.ps1` |

新版下載版手冊 FAQ 第 4 項要求：**M.U.T.-III 安裝完成後，執行原廠 `Del_PS_2.bat` 移除 PowerShell 2.0 相關元件**。已讀取的主安裝批次鏈未找到自動呼叫這個刪除入口，助手目前不自動執行這個刪除入口；原廠文件的要求與本助手已驗證的操作分開記錄。

刪除工具的實際範圍已讀取：它嘗試停用 PowerShell V2 可選功能、解除特定 GAC 組件，並移除 Registry64 的部分 `PowerShell\1` 登錄值與子鍵。其 DLL 搜尋位置包含 `C:\ps2DLC` 及工具目錄下的 `Binaries`／`ResourceBinaries`；**不能假設它會找到任意其他解壓位置，也不能只憑退出碼就宣稱完全解除**。

此工具在本助手環境的移除範圍及移除後相容性尚未驗證。若另行測試，需保留原執行原則，記錄實際執行與跳過項目，再核對 32／64 位元元件、SQL 服務及兩個程式。本報告不宣稱已完成元件清理，也不把原廠工具當作已驗證的完整系統還原工具。

先前 SEW25091 使用 Microsoft 暫時方案後，實際 PowerShell 執行版本仍回退至 5.1；該結果不能寫成恢復了真正的 2.0 引擎。新版也必須記錄實際版本。[Microsoft PowerShell 2.0 移除與暫時方案](https://support.microsoft.com/en-us/servicing/os/windows/docs/2025/08/powershell-2-0-removal-from-windows)

## 5. 本輪實機結果與驗收標準

以下記錄本輪各階段的實際狀態；**新版安裝與完整升級仍不能視為已通過**。

| 階段 | 本輪狀態 | 完成所需證據 |
| --- | --- | --- |
| 新版媒體 | 已核對 | ZIP 大小、SHA-256、原廠入口與差異調查 |
| 舊版備份 | 依使用者要求停止，未完成 | 已保留部分檔案；無 `Complete` manifest，不視為完整備份 |
| 卸載前重啟 | 已完成 | 實際開機時間為 2026-10-11 22:36:52（Asia/Taipei）；不代替後續重啟 |
| 原廠解除安裝 | 已完成 | 兩個程式目錄、`APP00`、應用程式安裝項目及捷徑已移除；兩個 SQL 引擎保留 |
| 解除安裝後重啟 | 已完成 | 實際開機時間為 2026-10-11 22:52:27.5（Asia/Taipei），待重啟旗標已清除 |
| 現行前置元件入口 | 126 項隔離測試及本機唯讀工作流程檢查通過 | 現有 NetFx3、兩架構 GAC、登錄與四項原則恢復證據通過；兩 SQL 引擎為 HealthyRunning，略過修復。尚未重做缺項安裝及完整 GUI/UAC 流程 |
| 新版完整安裝 | 尚未開始 | 本輪新產生的原廠最後檢查區塊、原廠與 SQL 程序結束 |
| 新版安裝後重啟 | 尚未完成 | 實際重啟及後續唯讀檢查 |
| 傳統版主畫面 | 尚未確認 | 可正常開啟，顯示 `PRG23061-03` |
| SE 主畫面 | 尚未確認 | 可正常開啟，顯示 `SEW26061-00` |
| SQL 與必要資料庫 | 尚未完成新版驗收 | 兩服務、實際 SQL 版本、`MUTMCB`／`CAESARCOMPDB2`／`CFFDB` 狀態及路徑 |
| 原廠 PowerShell 元件清理 | 未自動執行，未驗證 | 執行記錄、元件與執行原則核對，以及清理後兩程式仍能啟動 |
| 先前完整備份升級流程 | 未完成實機驗證，已不屬現行入口範圍 | 保留歷史紀錄，不能用手動重裝結果代替整合流程驗證 |

實測截圖應使用這次新版安裝與主畫面，不挪用舊版成功圖。若中途失敗，需保留原因、當時版本、備份位置與下一步，不能將 SE 單獨啟動或桌面出現兩個捷徑寫成完整成功。

## 6. 相容性與公開內容範圍

SQL Server 2014 不在 Microsoft 對 Windows 11 的官方支援範圍。新版安裝包仍使用同系列 SQL，因此即使本機後續安裝成功，也只代表這次環境實測通過。[Microsoft SQL／Windows 相容性表](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/install/windows/use-sql-server-in-windows)

本次不驗證 VCI、實車連線、車輛診斷、ECU 編程或寫入，也不替其他 Windows build、地區與舊版本保證相容性。備份還原至新版、SQL 完整還原與系統映像復原皆需另行驗證。

公開專案只保存教學、自製腳本與經整理的測試結果。原廠安裝 ZIP／PDF、SQL 備份、登錄匯出、原始日誌、機器識別資料與可能的車輛資料留在本機，不推送至 GitHub。

## 7. 先前整合方案的程式驗證紀錄

2026-10-11 在交付範圍改為僅處理前置元件前，使用 Windows 內建 64 位元 PowerShell 5.1 執行以下隔離測試，共 **276／276 通過**。測試使用暫存檔、虛擬程序與注入的系統操作，沒有對這台電腦執行卸載、SQL 清理或新版安裝；此結果不能代替第 5 節的實機驗收，**也不是新 `Prepare-MutPrerequisites.ps1` 入口的測試結果**。

| 測試檔 | 結果 | 驗證重點 |
| --- | --- | --- |
| `tests/Test-OneClick.ps1` | 89／89 | 既有安全守門、腳本語法與固定雜湊、完整安裝成功判定 |
| `tests/Test-MediaProfiles.ps1` | 25／25 | 新舊媒體識別、ZIP 根目錄與路徑檢查 |
| `tests/Test-VersionSelection.ps1` | 50／50 | 版本參數、主控接續、升級前程式關閉檢查、保留 SQL 分支 |
| `tests/Test-UpgradeGuards.ps1` | 68／68 | 備份檔案與 SQL 身分核驗、拒絕未知或損壞資料 |
| `tests/Test-UpgradeWorkflow.ps1` | 38／38 | 取消、中斷、備份失敗、真實重啟、卸載只接回監控 |
| `tests/Test-PreservedSql.ps1` | 6／6 | 既有 SQL 必須重新連線核對，未知版本不能視為就緒 |

新舊原廠 ZIP 均已依固定 SHA-256 核對，逐一核對 ZIP 項目並完成解壓。舊版解除安裝來源使用獨立的 `C:\MUT-Install\upgrade-uninstall-media\SEW25091`，不直接沿用可能被先前 SQL 安裝器增加檔案的工作目錄。

**先前整合方案的失敗重試存在來源核對限制。** SQL 安裝器可能在安裝來源目錄留下自行解壓的檔案，即使原廠 ZIP 未變，解壓目錄也可能不再與 ZIP 完全一致。原整合助手的嚴格來源驗證遇到這類差異會停止並保留現場，不直接覆蓋未知內容。因此不能保證再次執行該整合流程就能自動修復所有失敗；需要先依日誌確認來源差異，另行準備完整核對過的乾淨解壓來源。現行前置入口不解壓或核驗原廠主程式來源，原廠 ZIP 由使用者另行解壓。

原整合方案的升級進度保存在 `C:\MUT-Install\upgrade-state.json`。其設計會先原樣封存既有完成進度；只有原廠卸載完成、實際重啟及兩個 SQL 身分檢查通過後，才建立目標版本的主控進度。舊版主畫面確認不沿用到新版，備份也不會自動還原進新版。

原整合方案在備份完成、重啟接續及原廠卸載啟動前，會再次檢查兩版 M.U.T.、Internet Explorer 與 Windows Script Host 是否已關閉。無法辨識或仍在執行時停止並保留現場，不強制終止程式，也不重放卸載。

## 8. 現行手動安裝步驟與後續驗收

1. 完整解壓本專案，保留 `ps2DLC.zip` 與 `scripts`；執行 `Install-Prerequisites.cmd`，完成 Windows 管理員授權。
2. 若前置入口要求重啟，先重新啟動，再執行同一入口，直到前置檢查通過。未知錯誤保留日誌，不宣稱主程式已可用。
3. 另行完整解壓原廠 ZIP，確認入口位於 `C:\MUT-Install\SEW26061-00\MUT3_Install.bat`；本機舊版已完成原廠卸載，後續不需重做本輪卸載。
4. 對 `MUT3_Install.bat` 按右鍵，以系統管理員身分執行。依原廠畫面選 **Other → Install**，完成驅動程式精靈及其他原廠步驟。
5. 安裝完成後重新啟動 Windows，再核對傳統版 **PRG23061-03**、SE **SEW26061-00**、本輪 `InstLog.txt` 最後檢查、SQL 服務及必要資料庫。傳統版首次啟動需要時，透過 Windows 介面選擇 **Windows Based Script Host → Always**。

若原廠資料庫安裝失敗，前置入口只能在指定條件下修復已知 SQL 登錄權限，不能代替安裝 SQL、啟動服務或重新建立資料庫。原廠安裝尚在執行時先完成其結果處理；保留錯誤及日誌，關閉安裝器後再檢查。一般操作圖解見 [README](../README.md)。

## 9. 現行前置元件入口的驗證

2026-10-11 使用 Windows 內建 64 位元 PowerShell 5.1，完成以下隔離測試：

| 測試檔 | 結果 | 重點 |
| --- | --- | --- |
| `tests/Test-PrerequisitePreparation.ps1` | 60／60 | 健康系統略過修復、唯讀模式、來源校驗、失敗與舊紀錄拒絕、重啟接續、逾時保留程序、SQL 競態與入口範圍 |
| `tests/Test-PrerequisiteSql.ps1` | 66／66 | SQL 身分、來源與版本限定，MDAC 錯誤證據，未知狀態停止，正常／未安裝實例略過 |
| `tests/Test-OneClick.ps1` | 89／89 | 共用來源、安全守門與歷史流程的回歸檢查；不列入新入口的 126 項 |

本機另以原生 PowerShell 5.1 執行現行唯讀工作流程：Microsoft ZIP 與已解壓檔案逐一核對，NetFx3、17 組 GAC 身分、兩架構載入紀錄、登錄及四項執行原則還原證據通過；MUT3 與 CAESARCOMPDB 均符合已核對的執行中服務身分，因此計畫為 `Skip / HealthyRunning`，退出碼為 `0`。檢查沒有重新執行載入器、修改 ACL、啟動服務或安裝主程式。

這項唯讀驗證呼叫同一工作流程與實際收集器，不包含新 CMD 的完整互動/UAC 流程，也不代表在缺少元件的全新系統重新執行修復已成功。底層 Microsoft 元件及限定 ACL 修復的實機成功證據仍來自先前 SEW25091 安裝；SEW26061 主程式安裝與兩版主畫面待人工安裝後另行驗收。

現行入口只有前置元件與限定 ACL 輔助程式的啟動點；相容 `Install-MUT.cmd` 與 `Install-Mut.ps1 -Mode Auto` 均轉交前置流程。它不重放已取消的升級進度。已修復 SQL 權限時回傳 `3010`，記錄本次開機時間，要求實際重啟再檢查；健康 SQL 引擎與無法辨識的 SQL 狀態均不套用這項修復。