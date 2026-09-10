-- Posiran ERP sanitized ApplicationDb bootstrap seed
-- Source review: emp.dev.sql supplied 2026-09-10. Schema is NOT copied from that dump.
-- The release workflow generates current schema from the exact Ecomm source SHA, then appends this seed.
-- Installer replaces __ADMIN_PASSWORD_HASH__, __ADMIN_SECURITY_STAMP__, __ADMIN_CONCURRENCY_STAMP__
-- and __BOOK_CONNECTION_STRING__ before first import.

SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS=0;

-- Stable bootstrap identities. No operational/customer data from the source dump is retained.
SET @bootstrap_user_id = 'f2f4132e-11d3-4c65-8c1c-275062686200';
SET @company_id = 1;
SET @branch_id = 10001;
SET @book_id = 1000001;

-- Application roles: retain the product's canonical role model.
INSERT INTO `AppRoles` (`RoleId`,`RoleName`,`Description`,`RoleType`) VALUES
(1,'SuperAdmin','System Administrator',1),
(2,'CompanyAdmin','Company Administrator',2),
(3,'BookAdmin','Book Administrator',3),
(4,'SalesManager','Sales Manager',4),
(5,'PurchaseManager','Purchase Manager',5),
(6,'InventoryManager','Inventory Manager',6),
(7,'Accountant','Accountant',7),
(8,'Viewer','Read-only Viewer',8)
ON DUPLICATE KEY UPDATE `RoleName`=VALUES(`RoleName`),`Description`=VALUES(`Description`),`RoleType`=VALUES(`RoleType`);

INSERT INTO `AppRolePermissions` (`RoleId`,`PermissionType`) VALUES
(1,100),(1,101),(1,102),(1,103),(1,200),(1,201),(1,202),(1,203),(1,204),
(1,300),(1,301),(1,302),(1,303),(1,400),(1,401),(1,402),(1,403),
(1,500),(1,501),(1,502),(1,503),(1,600),(1,601);

-- Identity roles. Support uses the same fixed id as the current ApplicationDb migration.
INSERT INTO `aspnetroles` (`Id`,`Name`,`NormalizedName`,`ConcurrencyStamp`) VALUES
('1550555b-2552-4e0e-8cef-b0067af997df','SuperAdmin','SUPERADMIN',NULL),
('3c1da2e9-444b-4bda-8bf1-95f8dc0da967','CompanyAdmin','COMPANYADMIN',NULL),
('ba548be4-3cce-47dc-9f64-d374a3af6593','BookAdmin','BOOKADMIN',NULL),
('3f58cb88-1609-4231-9ee4-4b2f251f874b','SalesManager','SALESMANAGER',NULL),
('78d61c36-4061-4ba2-9282-ca3c0f273388','PurchaseManager','PURCHASEMANAGER',NULL),
('96a6cadb-b69e-4bda-928e-456ab8bc40bf','InventoryManager','INVENTORYMANAGER',NULL),
('78671195-abb5-4988-bbf2-7c94d24c3179','Accountant','ACCOUNTANT',NULL),
('d5902dda-a8f5-470a-8ba8-25bed2dbc2a6','Viewer','VIEWER',NULL),
('62f159bb-e466-4c95-9c2d-9e62c6555d2c','Support','SUPPORT',NULL)
ON DUPLICATE KEY UPDATE `Name`=VALUES(`Name`),`NormalizedName`=VALUES(`NormalizedName`);

-- Single bootstrap administrator. Password/security values are generated locally by Setup Host;
-- no password hash or security stamp from the supplied operational dump is published.
INSERT INTO `AspNetUsers`
(`Id`,`NationalCode`,`Mobile`,`SelectedBookId`,`SelectedBranchId`,`Email`,`Name`,`Family`,`Address`,`City`,`Region`,`PostalCode`,`Country`,`Phone`,`HomePage`,`CreatedAt`,`UpdatedAt`,`LastLoginAt`,`UserName`,`NormalizedUserName`,`NormalizedEmail`,`EmailConfirmed`,`PasswordHash`,`SecurityStamp`,`ConcurrencyStamp`,`PhoneNumber`,`PhoneNumberConfirmed`,`TwoFactorEnabled`,`LockoutEnd`,`LockoutEnabled`,`AccessFailedCount`)
VALUES
(@bootstrap_user_id,'2750626862','09143417944',@book_id,@branch_id,'','علی','میرزایی','','','','','','','',UTC_TIMESTAMP(6),NULL,'0001-01-01 00:00:00.000000','2750626862','2750626862',NULL,1,'__ADMIN_PASSWORD_HASH__','__ADMIN_SECURITY_STAMP__','__ADMIN_CONCURRENCY_STAMP__','09143417944',1,0,NULL,0,0);

-- Exactly one company, branch and book/office.
INSERT INTO `companies`
(`Id`,`CompanyId`,`Name`,`Description`,`UserId`,`Address`,`PhoneNumber`,`City`,`Region`,`CurrentBookId`,`BusinessType`,`LastSyncTime`,`LastSyncStatus`,`IsSynced`,`IsDeleted`,`DeletedAt`,`DeletedByUserId`,`CreatedAt`,`UpdatedAt`)
VALUES
(1,@company_id,'شرکت اصلی','شرکت پایه ایجادشده توسط Posiran ERP Setup',@bootstrap_user_id,NULL,NULL,NULL,NULL,@book_id,1,NULL,NULL,0,0,NULL,NULL,UTC_TIMESTAMP(6),UTC_TIMESTAMP(6));

INSERT INTO `branches`
(`BranchId`,`CompanyId`,`BranchSequence`,`BranchCode`,`BranchName`,`BranchType`,`Description`,`ApiAddress`,`Port`,`Province`,`City`,`PhysicalAddress`,`PostalCode`,`PhoneNumber`,`FaxNumber`,`Email`,`ManagerName`,`IsActive`,`OperationalStatus`,`LastSyncTime`,`LastSyncStatus`,`IsSynced`,`RowVersion`,`IsDeleted`,`DeletedAt`,`DeletedBy`,`CreatedAt`,`UpdatedAt`,`CreatedBy`,`UpdatedBy`,`ExternalGoodsApiSearchEnabled`,`AutoImportExternalGoods`,`ImportExternalGoodImages`,`ImportExternalGoodDetails`)
VALUES
(@branch_id,@company_id,1,'BR-001-001','شعبه اصلی','HeadOffice',NULL,'',NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,'علی میرزایی',1,'Online',NULL,NULL,0,CURRENT_TIMESTAMP(6),0,NULL,NULL,UTC_TIMESTAMP(6),UTC_TIMESTAMP(6),@bootstrap_user_id,@bootstrap_user_id,1,1,1,1);

INSERT INTO `books`
(`BookId`,`CompanyId`,`UserId`,`BookCode`,`Name`,`EnglishName`,`DatabaseType`,`ConnectionString`,`Description`,`IsActive`,`StartDate`,`EndDate`,`Version`,`IsDefault`,`EnableAuditLog`,`CommandTimeout`,`MaxConnections`,`LastSyncTime`,`LastSyncStatus`,`IsSynced`,`IsDeleted`,`DeletedAt`,`DeletedByUserId`,`CreatedAt`,`UpdatedAt`,`MigrationStatus`,`LastMigrationDate`,`LastMigrationError`,`LastMigrationVersion`)
VALUES
(@book_id,@company_id,@bootstrap_user_id,'BOOK-1-1','دفتر اصلی','Main Office',2,'__BOOK_CONNECTION_STRING__','دفتر پایه ایجادشده توسط Posiran ERP Setup',1,NULL,NULL,'1.0.0',1,1,30,10,NULL,NULL,0,0,NULL,NULL,UTC_TIMESTAMP(6),UTC_TIMESTAMP(6),'Completed',UTC_TIMESTAMP(6),NULL,'bootstrap');

INSERT INTO `BranchOperationalSettings`
(`BranchId`,`DefaultCashDeskId`,`DefaultPOSTerminalId`,`SmsAddress`,`Latitude`,`Longitude`,`AutoPrintQuickInvoice`,`QuickInvoicePrinterRole`,`QuickInvoiceCopies`,`UpdatedAt`)
VALUES (@branch_id,NULL,NULL,NULL,NULL,NULL,1,'CashierReceipt',1,UTC_TIMESTAMP(6));

-- Global SuperAdmin + company-scoped CompanyAdmin.
INSERT INTO `aspnetuserroles` (`UserId`,`RoleId`) VALUES
(@bootstrap_user_id,'1550555b-2552-4e0e-8cef-b0067af997df'),
(@bootstrap_user_id,'3c1da2e9-444b-4bda-8bf1-95f8dc0da967');

INSERT INTO `AppUserRoleAssignments`
(`UserId`,`CompanyId`,`BranchId`,`BookId`,`RoleId`,`AssignedDate`,`AssignedBy`,`IsActive`) VALUES
(@bootstrap_user_id,NULL,NULL,NULL,1,UTC_TIMESTAMP(6),'System',1),
(@bootstrap_user_id,@company_id,NULL,NULL,2,UTC_TIMESTAMP(6),'System',1);

INSERT INTO `aspnetuserclaims` (`UserId`,`ClaimType`,`ClaimValue`) VALUES
(@bootstrap_user_id,'FullName','علی میرزایی'),
(@bootstrap_user_id,'IsSuperAdmin','true'),
(@bootstrap_user_id,'SelectedCompanyId','1'),
(@bootstrap_user_id,'SelectedCompanyName','شرکت اصلی'),
(@bootstrap_user_id,'SelectedBranchId','10001'),
(@bootstrap_user_id,'SelectedBranchName','شعبه اصلی'),
(@bootstrap_user_id,'SelectedBookId','1000001'),
(@bootstrap_user_id,'SelectedBookName','دفتر اصلی');

INSERT INTO `systemsettings`
(`EnableWebsiteSync`,`EnableDbSync`,`GoodsSyncIntervalSeconds`,`GoodsSyncBatchSize`,`EnableDatabaseBackup`,`BackupIntervalMinutes`,`BackupEmail`,`LastModified`)
VALUES (0,0,30,10,1,720,NULL,UTC_TIMESTAMP(6));

SET FOREIGN_KEY_CHECKS=1;
