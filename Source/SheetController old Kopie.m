/*
 Copyright © Roman Zechmeister, 2011
 
 Diese Datei ist Teil von GPG Keychain Access.
 
 GPG Keychain Access ist freie Software. Sie können es unter den Bedingungen 
 der GNU General Public License, wie von der Free Software Foundation 
 veröffentlicht, weitergeben und/oder modifizieren, entweder gemäß 
 Version 3 der Lizenz oder (nach Ihrer Option) jeder späteren Version.
 
 Die Veröffentlichung von GPG Keychain Access erfolgt in der Hoffnung, daß es Ihnen 
 von Nutzen sein wird, aber ohne irgendeine Garantie, sogar ohne die implizite 
 Garantie der Marktreife oder der Verwendbarkeit für einen bestimmten Zweck. 
 Details finden Sie in der GNU General Public License.
 
 Sie sollten ein Exemplar der GNU General Public License zusammen mit diesem 
 Programm erhalten haben. Falls nicht, siehe <http://www.gnu.org/licenses/>.
*/

#import "SheetController.h"
#import "ActionController.h"
#import "KeychainController.h"
#import <AddressBook/AddressBook.h>


@interface SheetController ()
@property (assign) NSView *displayedView;

- (void)runSheetForWindow:(NSWindow *)window;
- (void)closeSheet;
- (void)setStandardExpirationDates;
- (void)setDataFromAddressBook;
- (BOOL)checkName;
- (BOOL)checkEmailMustSet:(BOOL)mustSet;
- (BOOL)checkComment;
- (BOOL)checkPassphrase;

- (void)alertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo;
- (void)openSavePanelDidEnd:(NSOpenPanel *)sheet returnCode:(int)returnCode contextInfo:(NSDictionary *)contextInfo;
- (BOOL)panel:(NSOpenPanel *)sender validateURL:(NSURL *)url error:(NSError **)outError;

@end

@implementation SheetController
@synthesize allowSecretKeyExport, allowEdit, myKey, myString, mySubkey, foundKeys, msgText, 
	pattern, name, email, comment, passphrase, confirmPassphrase, availableLengths, length, 
	hasExpirationDate, expirationDate, minExpirationDate, maxExpirationDate, sigType, 
	localSig, emailAddresses, secretKeys, secretKeyFingerprints, secretKeyId, userIDs;

static SheetController *_sharedInstance = nil;



+ (id)sharedInstance {
	if (_sharedInstance == nil) {
		_sharedInstance = [[self alloc] init];
	}
	return _sharedInstance;
}

- (id)init {
	if (self = [super init]) {
		[NSBundle loadNibNamed:@"ModalSheets" owner:self];
		exportFormat = 1;
	}
	return self;
}


- (void)algorithmPreferences:(GPGKey *)key editable:(BOOL)editable {
	self.myKey = key;
	
	NSUInteger count = [[myKey userIDs] count], arrayCount = 0;
	
	NSMutableArray *userIDsArray = [NSMutableArray arrayWithCapacity:count];
	
	
	for (GPGUserID *userID in [myKey userIDs]) {
		NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithObjectsAndKeys:[userID userID], @"userID", 
									 [userID cipherPreferences], @"cipherPreferences", 
									 [userID digestPreferences], @"digestPreferences", 
									 [userID compressPreferences], @"compressPreferences", 
									 [userID otherPreferences], @"otherPreferences", nil];
		
		NSUInteger i = 0, index = [userID index];
		for (; i < arrayCount; i++) {
			if ([[userIDsArray objectAtIndex:i] index] > index) {
				break;
			}
		}	
		[userIDsArray insertObject:dict atIndex:i];
	}
	self.userIDs = userIDsArray;
	self.allowEdit = editable;
	
	currentAction = AlgorithmPreferencesAction;
	self.displayedView = editAlgorithmPreferencesView;
	
	[self runSheetForWindow:mainWindow];
}
- (void)algorithmPreferences_Action {
	if (allowEdit) {
		[actionController editAlgorithmPreferencesForKey:myKey preferences:userIDs];
	}
	[self closeSheet];
}




- (void)addSubkey:(GPGKey *)key {
	self.msgText = [NSString stringWithFormat:localized(@"GenerateSubkey_Msg"), [key userID], [key shortKeyID]];
	self.length = 2048;
	self.keyType = 3;
	[self setStandardExpirationDates];
	self.hasExpirationDate = NO;

	
	self.myKey = key;
	currentAction = AddSubkeyAction;
	self.displayedView = generateSubkeyView;
	
	[self runSheetForWindow:inspectorWindow];
}
- (void)addSubkey_Action {
	[actionController addSubkeyForKey:myKey type:keyType length:length daysToExpire:hasExpirationDate ? getDaysToExpire (expirationDate) : 0];
	[self closeSheet];
}

- (void)addUserID:(GPGKey *)key {
	self.msgText = [NSString stringWithFormat:localized(@"GenerateUserID_Msg"), [key userID], [key shortKeyID]];
	
	[self setDataFromAddressBook];
	self.comment = @"";

	
	self.myKey = key;
	currentAction = AddUserIDAction;
	self.displayedView = generateUserIDView;
	
	[self runSheetForWindow:inspectorWindow];
}
- (void)addUserID_Action {
	[actionController addUserIDForKey:myKey name:name email:email comment:comment];
	[self closeSheet];
}

- (void)addSignature:(GPGKey *)key userID:(NSString *)userID {
	self.msgText = [NSString stringWithFormat:localized(userID ? @"GenerateUidSignature_Msg" : @"GenerateSignature_Msg"), [key userID], [key shortKeyID]];
	self.sigType = 0;
	self.localSig = NO;
	[self setStandardExpirationDates];
	self.hasExpirationDate = NO;
	
		
	NSString *defaultKey = [[GPGOptions sharedOptions] valueForKey:@"default-key"];
	switch ([defaultKey length]) {
		case 9:
		case 17:
		case 33:
		case 41:
			if ([defaultKey hasPrefix:@"0"]) {
				defaultKey = [defaultKey substringFromIndex:1];
			}
			break;
		case 10:
		case 18:
		case 34:
		case 42:
			if ([defaultKey hasPrefix:@"0x"]) {
				defaultKey = [defaultKey substringFromIndex:2];
			}
			break;
	}

	self.secretKeyId = 0;
	
	NSSet *secKeySet = [keychainController secretKeys];
	NSMutableArray *secKeys = [NSMutableArray arrayWithCapacity:[secKeySet count]];
	NSMutableArray *fingerprints = [NSMutableArray arrayWithCapacity:[secKeySet count]];
	GPGKey *aKey;
	NSSet *allKeys = [keychainController allKeys];
	int i = 0;
	
	for (NSString *fingerprint in secKeySet) {
		aKey = [allKeys member:fingerprint];
		if (defaultKey && [aKey.textForFilter rangeOfString:defaultKey].length != 0) {
			self.secretKeyId = i;
			defaultKey = nil;
		}
		[secKeys addObject:[NSString stringWithFormat:@"%@, %@", aKey.shortKeyID, aKey.userID]];
		[fingerprints addObject:fingerprint];
		i++;
	}
	self.secretKeys = secKeys;
	self.secretKeyFingerprints = fingerprints;

	
	
	self.myKey = key;
	self.myString = userID;
	currentAction = AddSignatureAction;
	self.displayedView = generateSignatureView;
	
	[self runSheetForWindow:userID ? inspectorWindow : mainWindow];
}
- (void)addSignature_Action {
	[actionController addSignatureForKey:myKey andUserID:myString signKey:[secretKeyFingerprints objectAtIndex:secretKeyId] type:sigType local:localSig daysToExpire:hasExpirationDate ? getDaysToExpire (expirationDate) : 0];
	[self closeSheet];
}

- (void)changeExpirationDate:(GPGKey *)key subkey:(GPGSubkey *)subkey {
	NSDate *aDate;
	if (subkey) {
		self.msgText = [NSString stringWithFormat:localized(@"ChangeSubkeyExpirationDate_Msg"), [subkey shortKeyID], [key userID], [key shortKeyID]];
		aDate = [subkey expirationDate];
	} else {
		self.msgText = [NSString stringWithFormat:localized(@"ChangeExpirationDate_Msg"), [key userID], [key shortKeyID]];
		aDate = [key expirationDate];
	}

	[self setStandardExpirationDates];
	if (aDate) {
		self.hasExpirationDate = YES;
		self.expirationDate = aDate;
		self.minExpirationDate = [self.minExpirationDate earlierDate:aDate];
	} else {
		self.hasExpirationDate = NO;
	}
	
	
	self.myKey = key;
	self.mySubkey = subkey;
	currentAction = ChangeExpirationDateAction;
	self.displayedView = changeExpirationDateView;
	
	[self runSheetForWindow:inspectorWindow];
}
- (void)changeExpirationDate_Action {
	[actionController changeExpirationDateForKey:myKey subkey:mySubkey daysToExpire:hasExpirationDate ? getDaysToExpire (expirationDate) : 0];
	[self closeSheet];
}

- (void)searchKeys {
	self.pattern = @"";
	
	currentAction = SearchKeysAction;
	self.displayedView = searchKeysView;
	
	[self runSheetForWindow:mainWindow];
}
- (void)searchKeys_Action {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	NSArray *keys = [actionController searchKeysWithPattern:pattern];
	
	if ([keys count] == 0) {
		[self performSelectorOnMainThread:@selector(showResultText:) withObject:localized(@"No keys found!") waitUntilDone:NO];
	} else {
		[self performSelectorOnMainThread:@selector(showFoundKeys:) withObject:keys waitUntilDone:NO];
	}

	[pool drain];
}
- (void)showFoundKeys:(NSArray *)keys {
	NSMutableArray *dicts = [NSMutableArray arrayWithCapacity:[keys count]];
	
	NSDateFormatter *dateFormatter = [[[NSDateFormatter alloc] init] autorelease];
	[dateFormatter setDateStyle:NSDateFormatterMediumStyle];
	[dateFormatter setTimeStyle:NSDateFormatterNoStyle];

	GPGKeyAlgorithmNameTransformer *algorithmNameTransformer = [[GPGKeyAlgorithmNameTransformer new] autorelease];
	
	for (GPGRemoteKey *key in keys) {
		NSNumber *selected;
		NSDictionary *stringAttributes;
		NSMutableAttributedString *description;
		
		if (key.expired || key.revoked) {
			selected = [NSNumber numberWithBool:NO];
			stringAttributes = [NSDictionary dictionaryWithObject:[NSColor redColor] forKey:NSForegroundColorAttributeName];
		} else {
			selected = [NSNumber numberWithBool:YES];
			stringAttributes = nil;
		}
		
		NSString *tempDescription = [NSString stringWithFormat:localized(@"%@, %@ (%lu bit), created: %@"), 
						   key.keyID, //Schlüssel ID
						   [algorithmNameTransformer transformedIntegerValue:key.algorithm], //Algorithmus
						   key.length, //Länge
						   [dateFormatter stringFromDate:key.creationDate]]; //Erstellt

		description = [[[NSMutableAttributedString alloc] initWithString:tempDescription attributes:stringAttributes] autorelease];
		
		for (GPGRemoteUserID *userID in key.userIDs) {
			[description appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n	%@", userID.userID]]];
		}
		
		[dicts addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:description, @"description", selected, @"selected", [NSNumber numberWithUnsignedInteger:[key.userIDs count] + 1], @"lines", key, @"key", nil]];
	}
	
	self.foundKeys = dicts;

	currentAction = ShowFoundKeysAction;
	self.displayedView = foundKeysView;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
	NSDictionary *foundKey = [[foundKeysController arrangedObjects] objectAtIndex:row];
	return [[foundKey objectForKey:@"lines"] integerValue] * [tableView rowHeight] + 1;
}
- (BOOL)tableView:(NSTableView *)tableView shouldTypeSelectForEvent:(NSEvent *)event withCurrentSearchString:(NSString *)searchString {
	if ([event type] == NSKeyDown && [event keyCode] == 49) { //Leertaste gedrückt
		NSArray *selectedKeys = [foundKeysController selectedObjects];
		if ([selectedKeys count] > 0) {
			NSNumber *selected = [NSNumber numberWithBool:![[[selectedKeys objectAtIndex:0] objectForKey:@"selected"] boolValue]];
			for (NSMutableDictionary *foundKey in [foundKeysController selectedObjects]) {
				[foundKey setObject:selected forKey:@"selected"];
			}
		}
	}
	return NO;
}



- (void)showResult:(NSString *)text {
	[self showResultText:text];
	[self runSheetForWindow:mainWindow];
}
- (void)showResultText:(NSString *)text {
	self.msgText = @"";
	self.msgText = text;
	self.displayedView = resultView;
}


- (void)receiveKeys {
	self.pattern = @"";
	
	currentAction = ReceiveKeysAction;
	self.displayedView = receiveKeysView;
	
	[self runSheetForWindow:mainWindow];
}
- (void)receiveKeys_Action:(NSSet *)keyIDs {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	[self performSelectorOnMainThread:@selector(showResultText:) withObject:[actionController receiveKeysWithIDs:keyIDs] waitUntilDone:NO];
	[pool drain];
}


- (void)generateNewKey {
	self.length = 2048;
	self.keyType = 1;
	[self setStandardExpirationDates];
	self.hasExpirationDate = NO;
	
	[self setDataFromAddressBook];
	self.comment = @"";
	self.passphrase = @"";
	self.confirmPassphrase = @"";
	
	currentAction = NewKeyAction;
	self.displayedView = newKeyView;
	
	[self runSheetForWindow:mainWindow];
}


- (void)newKey_Action {
	[actionController generateNewKeyWithName:name email:email comment:comment passphrase:((GPG_VERSION == 1) ? passphrase : nil) type:keyType length:length daysToExpire:hasExpirationDate ? getDaysToExpire (expirationDate) : 0];
	[self closeSheet];
}


- (void)closeSheet {
	if ([NSThread isMainThread]) {
		[self cancelButton:nil];
	} else {
		[self performSelectorOnMainThread:@selector(cancelButton:) withObject:nil waitUntilDone:NO];
	}
}

- (IBAction)okButton:(id)sender {
	if (![sheetWindow makeFirstResponder:sheetWindow]) {
		[sheetWindow endEditingFor:nil];
	}
	switch (currentAction) {
		case NewKeyAction:
			if (![self checkName]) return;
			if (![self checkEmailMustSet:NO]) return;
			if (![self checkComment]) return;
			if (GPG_VERSION == 1) {
				if (![self checkPassphrase]) return;
			}
			
			self.msgText = localized(@"GenerateEntropy_Msg");
			[NSThread detachNewThreadSelector:@selector(newKey_Action) toTarget:self withObject:nil];
			break;
		case AddSubkeyAction:
			self.msgText = localized(@"GenerateEntropy_Msg");
			[NSThread detachNewThreadSelector:@selector(addSubkey_Action) toTarget:self withObject:nil];
			break;
		case AddUserIDAction:
			if (![self checkName]) return;
			if (![self checkEmailMustSet:NO]) return;
			if (![self checkComment]) return;
	
			[NSThread detachNewThreadSelector:@selector(addUserID_Action) toTarget:self withObject:nil];
			break;
		case AddSignatureAction:
			[NSThread detachNewThreadSelector:@selector(addSignature_Action) toTarget:self withObject:nil];
			break;
		case ChangeExpirationDateAction:
			[NSThread detachNewThreadSelector:@selector(changeExpirationDate_Action) toTarget:self withObject:nil];
			break;
		case SearchKeysAction:
			self.msgText = localized(@"SearchingKeys_Msg");
			[NSThread detachNewThreadSelector:@selector(searchKeys_Action) toTarget:self withObject:nil];
			break;
		case ReceiveKeysAction: {
			NSSet *keyIDs = keyIDsFromString(pattern);
			if (!keyIDs) {
				NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_NoKeyID"), nil, nil, nil);
				return;
			}
			[NSThread detachNewThreadSelector:@selector(receiveKeys_Action:) toTarget:self withObject:keyIDs];
			break; }
		case ShowFoundKeysAction: {
			NSMutableSet *keyIDs = [NSMutableSet setWithCapacity:[foundKeys count]];
			for (NSDictionary *foundKey in foundKeys) {
				if ([[foundKey objectForKey:@"selected"] boolValue]) {
					[keyIDs addObject:[[foundKey objectForKey:@"key"] keyID]];
				}
			}
			if ([keyIDs count] == 0) {
				NSBeep();
				return;
			}
			[NSThread detachNewThreadSelector:@selector(receiveKeys_Action:) toTarget:self withObject:keyIDs];			
			break; }
		case AlgorithmPreferencesAction:
			[self algorithmPreferences_Action];
			break;
		/*default:
			[self closeSheet];*/
	}
}
- (IBAction)cancelButton:(id)sender {
	currentAction = NoAction;
	self.msgText = nil;
	
	self.myKey = nil;
	self.mySubkey = nil;
	self.myString = nil;
	[sheetWindow orderOut:self];
	[NSApp stopModal];
}

- (void)runSheetForWindow:(NSWindow *)window {
	static NSLock *lock = nil;
	if (!lock) {
		lock = [NSLock new];
	}
	if ([lock tryLock]) {
		[NSApp beginSheet:sheetWindow modalForWindow:window modalDelegate:nil didEndSelector:nil contextInfo:nil];
		[NSApp runModalForWindow:sheetWindow];
		[NSApp endSheet:sheetWindow];
		
		self.displayedView = nil;
		[lock unlock];
	}
}


- (void)setStandardExpirationDates {
	//Setzt minExpirationDate einen Tag in die Zukunft.
	//Setzt maxExpirationDate 500 Jahre in die Zukunft.
	//Setzt expirationDate ein Jahr in die Zukunft.	
	
	NSDateComponents *dateComponents = [[[NSDateComponents alloc] init] autorelease];
	NSCalendar *calendar = [NSCalendar currentCalendar];
	NSDate *curDate = [NSDate date];
	[dateComponents setDay:1];
	self.minExpirationDate = [calendar dateByAddingComponents:dateComponents toDate:curDate options:0];
	[dateComponents setDay:0];
	[dateComponents setYear:10];
	self.expirationDate = [calendar dateByAddingComponents:dateComponents toDate:curDate options:0]; 	
	[dateComponents setYear:500];
	self.maxExpirationDate = [calendar dateByAddingComponents:dateComponents toDate:curDate options:0]; 	
}
- (void)setDataFromAddressBook {
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	ABPerson *myPerson = [[ABAddressBook sharedAddressBook] me];
	if (myPerson) {
		NSString *abFirstName = [myPerson valueForProperty:kABFirstNameProperty];
		NSString *abLastName = [myPerson valueForProperty:kABLastNameProperty];
		
		if (abFirstName && abLastName) {
			self.name = [NSString stringWithFormat:@"%@ %@", abFirstName, abLastName];
		} else if (abFirstName) {
			self.name = abFirstName;
		} else if (abLastName) {
			self.name = abLastName;
		} else {
			self.name = @"";
		}
		
		ABMultiValue *abEmailAddresses = [myPerson valueForProperty:kABEmailProperty];
		
		NSUInteger count = [abEmailAddresses count];
		if (count > 0) {
			NSMutableArray *newEmailAddresses = [NSMutableArray arrayWithCapacity:count];
			for (NSUInteger i = 0; i < count; i++) {
				[newEmailAddresses addObject:[abEmailAddresses valueAtIndex:i]];
			}
			self.emailAddresses = [newEmailAddresses copy];
			self.email = [emailAddresses objectAtIndex:0];
		} else {
			self.emailAddresses = nil;
			self.email = @"";
		}
	} else {
		self.name = @"";
		self.email = @"";
	}
	[pool drain];
}


- (BOOL)checkName {
	if ([name length] < 5) {
		NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_NameToShort"), nil, nil, nil);
		return NO;
	}
	if ([name length] > 500) {
		NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_NameToLong"), nil, nil, nil);
		return NO;
	}
	if ([name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"<>"]].length != 0) {
		NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_InvalidCharInName"), nil, nil, nil);
		return NO;
	}
	if ([name characterAtIndex:0] <= '9' && [name characterAtIndex:0] >= '0') {
		NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_NameStartWithDigit"), nil, nil, nil);
		return NO;
	}
	return YES;
}

- (BOOL)checkEmailMustSet:(BOOL)mustSet {
	if (!email) {
		email = @"";
	}
	
	if (!mustSet && [email length] == 0) {
		return YES;
	}
	if ([email length] > 254) {
		NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_EmailToLong"), nil, nil, nil);
		return NO;
	}
	if ([email length] < 4) {
		goto emailIsInvalid;
	}
	if ([email hasPrefix:@"@"] || [email hasSuffix:@"@"] || [email hasSuffix:@"."]) {
		goto emailIsInvalid;
	}
	NSArray *components = [email componentsSeparatedByString:@"@"];
	if ([components count] != 2) {
		goto emailIsInvalid;
	} 
	if ([(NSString *)[components objectAtIndex:0] length] > 64) {
		goto emailIsInvalid;
	}
	
	NSMutableCharacterSet *charSet = [NSMutableCharacterSet characterSetWithRange:(NSRange){128, 65408}];
	[charSet addCharactersInString:@"01234567890_-+@.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"];
	[charSet invert];
	
	if ([[components objectAtIndex:0] rangeOfCharacterFromSet:charSet].length != 0) {
		goto emailIsInvalid;
	}
	[charSet addCharactersInString:@"+"];
	if ([[components objectAtIndex:1] rangeOfCharacterFromSet:charSet].length != 0) {
		goto emailIsInvalid;
	}
	
	return YES;
	
emailIsInvalid: //Hierher wird gesprungen, wenn die E-Mail-Adresse ungültig ist und nicht eine spezielle Meldung ausgegeben werden soll.
	NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_InvalidEmail"), nil, nil, nil);
	return NO;
}

- (BOOL)checkComment {
	if (!comment) {
		comment = @"";
		return YES;
	}
	if ([comment length] == 0) {
		return YES;
	}
	if ([comment length] > 500) {
		NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_CommentToLong"), nil, nil, nil);
		return NO;
	}
	if ([comment rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"()"]].length != 0) {
		NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_InvalidCharInComment"), nil, nil, nil);
		return NO;
	}
	return YES;
}

- (BOOL)checkPassphrase {
	if (!passphrase) {
		passphrase = @"";
	}
	if (!confirmPassphrase) {
		confirmPassphrase = @"";
	}
	if (![passphrase isEqualToString:confirmPassphrase]) {
		NSRunAlertPanel(localized(@"Error"), localized(@"CheckError_PassphraseMissmatch"), nil, nil, nil);
		return NO;
	}
	//TODO: Hinweis bei leerer, einfacher oder kurzer Passphrase.
	
	return YES;
}


- (NSView *)displayedView {
	return displayedView;
}
- (void)setDisplayedView:(NSView *)value {
	if (displayedView != value) {
		if (displayedView == progressView) {
			[progressIndicator stopAnimation:nil];
		}
		[displayedView removeFromSuperview];
		displayedView = value;
		if (value != nil) {
			
			if (value == newKeyView) { //Passphrase-Felder nur bei GPG 1.4.x anzeigen.
				NSUInteger resizingMask;
				NSSize newSize;
				if (GPG_VERSION == 1) {
					if ([newKey_passphraseSubview isHidden] == YES) {
						[newKey_passphraseSubview setHidden:NO];
						newSize = [newKeyView frame].size;
						newSize.height += [newKey_passphraseSubview frame].size.height;
						
						resizingMask = [newKey_topSubview autoresizingMask];
						[newKey_topSubview setAutoresizingMask:NSViewMinYMargin | NSViewWidthSizable];
						[newKeyView setFrameSize:newSize];
						[newKey_topSubview setAutoresizingMask:resizingMask];
					}					
				} else {
					if ([newKey_passphraseSubview isHidden] == NO) {
						[newKey_passphraseSubview setHidden:YES];
						newSize = [newKeyView frame].size;
						newSize.height -= [newKey_passphraseSubview frame].size.height;
						
						resizingMask = [newKey_topSubview autoresizingMask];
						[newKey_topSubview setAutoresizingMask:NSViewMinYMargin | NSViewWidthSizable];
						[newKeyView setFrameSize:newSize];
						[newKey_topSubview setAutoresizingMask:resizingMask];
					}
				}
			}
			
			
			NSRect oldRect, newRect;
			oldRect = [sheetWindow frame];
			newRect.size = [value frame].size;
			newRect.origin.x = oldRect.origin.x + (oldRect.size.width - newRect.size.width) / 2;
			newRect.origin.y = oldRect.origin.y + oldRect.size.height - newRect.size.height;

			
			[sheetWindow setFrame:newRect display:YES animate:YES];
			[sheetWindow setContentSize:newRect.size];
			
			[sheetView addSubview:value];
			if ([value nextKeyView]) {
				[sheetWindow makeFirstResponder:[value nextKeyView]];
			}
			if (value == progressView) {
				//self.msgText = @"";
				[progressIndicator startAnimation:nil];
			}
		}
	}
}


- (NSInteger)keyType {
	return keyType;
}
- (void)setKeyType:(NSInteger)value {
	keyType = value;
	if (value == 2 || value == 3) {
		keyLengthFormatter.minKeyLength = 1024;
		keyLengthFormatter.maxKeyLength = 3072;
		self.length = [keyLengthFormatter checkedValue:length];
		self.availableLengths = [NSArray arrayWithObjects:@"1024", @"2048", @"3072", nil];
	} else {
		keyLengthFormatter.minKeyLength = 1024;
		keyLengthFormatter.maxKeyLength = 4096;
		self.length = [keyLengthFormatter checkedValue:length];
		self.availableLengths = [NSArray arrayWithObjects:@"1024", @"2048", @"3072", @"4096", nil];
	}
}


- (void)showProgressSheet {
	[self performSelectorOnMainThread:@selector(setDisplayedView:) withObject:progressView waitUntilDone:YES];
	//[NSThread detachNewThreadSelector:@selector(setDisplayedView:) toTarget:self withObject:progressView];
}
- (void)endProgressSheet {
	if (self.displayedView == progressView) {
		[self closeSheet];
	}
}



//Für Algorithmus Präferenzen

- (NSArray *)tokenField:(NSTokenField *)tokenField shouldAddObjects:(NSArray *)tokens atIndex:(NSUInteger)index {	
	NSMutableArray *newTokens = [NSMutableArray arrayWithCapacity:[tokens count]];
	
	NSString *tokenPrefix;
	switch ([tokenField tag]) {
		case 1:
			tokenPrefix = @"S";
			break;
		case 2:
			tokenPrefix = @"H";
			break;
		case 3:
			tokenPrefix = @"Z";
			break;
		default:
			return newTokens;
	}
	
	for (NSString *token in tokens) {
		if ([token hasPrefix:tokenPrefix]) {
			[newTokens addObject:token];
		}
	}
	return newTokens;
}

- (id)tokenField:(NSTokenField *)tokenField representedObjectForEditingString:(NSString *)editingString {
	static NSDictionary *algorithmIdentifiers = nil;
	if (!algorithmIdentifiers) {
		algorithmIdentifiers = [[NSDictionary alloc] initWithObjectsAndKeys:@"S0", localized(@"CIPHER_ALGO_NONE"), 
								@"S1", localized(@"CIPHER_ALGO_IDEA"), 
								@"S2", localized(@"CIPHER_ALGO_3DES"), 
								@"S3", localized(@"CIPHER_ALGO_CAST5"), 
								@"S4", localized(@"CIPHER_ALGO_BLOWFISH"), 
								@"S7", localized(@"CIPHER_ALGO_AES"), 
								@"S8", localized(@"CIPHER_ALGO_AES192"), 
								@"S9", localized(@"CIPHER_ALGO_AES256"), 
								@"S10", localized(@"CIPHER_ALGO_TWOFISH"), 
								@"S11", localized(@"CIPHER_ALGO_CAMELLIA128"), 
								@"S12", localized(@"CIPHER_ALGO_CAMELLIA192"), 
								@"S13", localized(@"CIPHER_ALGO_CAMELLIA256"), 
								@"H1", localized(@"DIGEST_ALGO_MD5"), 
								@"H2", localized(@"DIGEST_ALGO_SHA1"), 
								@"H3", localized(@"DIGEST_ALGO_RMD160"), 
								@"H8", localized(@"DIGEST_ALGO_SHA256"), 
								@"H9", localized(@"DIGEST_ALGO_SHA384"), 
								@"H10", localized(@"DIGEST_ALGO_SHA512"), 
								@"H11", localized(@"DIGEST_ALGO_SHA224"), 
								@"Z0", localized(@"COMPRESS_ALGO_NONE"), 
								@"Z1", localized(@"COMPRESS_ALGO_ZIP"), 
								@"Z2", localized(@"COMPRESS_ALGO_ZLIB"), 
								@"Z3", localized(@"COMPRESS_ALGO_BZIP2"), nil];
	}
	NSString *algorithmIdentifier = [algorithmIdentifiers objectForKey:[editingString uppercaseString]];
	if (!algorithmIdentifier) {
		algorithmIdentifier = editingString;
	}
	return [algorithmIdentifier uppercaseString];
}

- (NSString *)tokenField:(NSTokenField *)tokenField displayStringForRepresentedObject:(id)representedObject {
	static NSDictionary *algorithmNames = nil;
	if (!algorithmNames) {
		algorithmNames = [[NSDictionary alloc] initWithObjectsAndKeys:localized(@"CIPHER_ALGO_NONE"), @"S0", 
						   localized(@"CIPHER_ALGO_IDEA"), @"S1", 
						   localized(@"CIPHER_ALGO_3DES"), @"S2", 
						   localized(@"CIPHER_ALGO_CAST5"), @"S3", 
						   localized(@"CIPHER_ALGO_BLOWFISH"), @"S4", 
						   localized(@"CIPHER_ALGO_AES"), @"S7", 
						   localized(@"CIPHER_ALGO_AES192"), @"S8", 
						   localized(@"CIPHER_ALGO_AES256"), @"S9", 
						   localized(@"CIPHER_ALGO_TWOFISH"), @"S10", 
						   localized(@"CIPHER_ALGO_CAMELLIA128"), @"S11", 
						   localized(@"CIPHER_ALGO_CAMELLIA192"), @"S12", 
						   localized(@"CIPHER_ALGO_CAMELLIA256"), @"S13", 
						   localized(@"DIGEST_ALGO_MD5"), @"H1", 
						   localized(@"DIGEST_ALGO_SHA1"), @"H2", 
						   localized(@"DIGEST_ALGO_RMD160"), @"H3", 
						   localized(@"DIGEST_ALGO_SHA256"), @"H8", 
						   localized(@"DIGEST_ALGO_SHA384"), @"H9", 
						   localized(@"DIGEST_ALGO_SHA512"), @"H10", 
						   localized(@"DIGEST_ALGO_SHA224"), @"H11", 
						   localized(@"COMPRESS_ALGO_NONE"), @"Z0", 
						   localized(@"COMPRESS_ALGO_ZIP"), @"Z1", 
						   localized(@"COMPRESS_ALGO_ZLIB"), @"Z2", 
						   localized(@"COMPRESS_ALGO_BZIP2"), @"Z3", nil];
	}
	NSString *displayString = [algorithmNames objectForKey:[representedObject description]];
	if (!displayString) {
		displayString = [representedObject description];
	}
	return displayString;
}





//Für Öffnen- und Speichern-Sheets.

- (void)addPhoto:(GPGKey *)key {
	openPanel = [NSOpenPanel openPanel];
	
	[openPanel setAllowsMultipleSelection:NO];
	[openPanel setDelegate:self];
	
	NSArray *fileTypes = [NSArray arrayWithObjects:@"jpg", @"jpeg", nil];
	NSDictionary *contextInfo = [[NSDictionary alloc] initWithObjectsAndKeys:key, @"key",[NSNumber numberWithInt:GKOpenSavePanelAddPhotoAction], @"action", nil];

	[openPanel beginSheetForDirectory:nil file:nil types:fileTypes modalForWindow:inspectorWindow modalDelegate:self didEndSelector:@selector(openSavePanelDidEnd:returnCode:contextInfo:) contextInfo:contextInfo];			
	[NSApp runModalForWindow:inspectorWindow];
}

- (void)importKey {
	openPanel = [NSOpenPanel openPanel];
	
	[openPanel setAllowsMultipleSelection:YES];
	
	NSArray *fileTypes = [NSArray arrayWithObjects:@"gpgkey", @"asc", @"key", @"gpg", @"pgp", nil];
	NSDictionary *contextInfo = [[NSDictionary alloc] initWithObjectsAndKeys:[NSNumber numberWithInt:GKOpenSavePanelImportKeyAction], @"action", nil];
	
	[openPanel beginSheetForDirectory:nil file:nil types:fileTypes modalForWindow:mainWindow modalDelegate:self didEndSelector:@selector(openSavePanelDidEnd:returnCode:contextInfo:) contextInfo:contextInfo];
	[NSApp runModalForWindow:mainWindow];
}
- (void)exportKeys:(NSSet *)keys {
	savePanel = [NSSavePanel savePanel];
	
	[savePanel setAccessoryView:exportKeyOptionsView];
	
	[savePanel setAllowsOtherFileTypes:YES];
	[savePanel setCanSelectHiddenExtension:YES];
	self.exportFormat = exportFormat;
	
	
	NSString *filename;
	if ([keys count] == 1) {
		filename = [[keys anyObject] shortKeyID];
	} else {
		filename = localized(@"untitled");
	}
	NSDictionary *contextInfo = [[NSDictionary alloc] initWithObjectsAndKeys:keys, @"keys", [NSNumber numberWithInt:GKOpenSavePanelExportKeyAction], @"action", nil];
	
	[savePanel beginSheetForDirectory:nil file:filename modalForWindow:mainWindow modalDelegate:self didEndSelector:@selector(openSavePanelDidEnd:returnCode:contextInfo:) contextInfo:contextInfo];
	[NSApp runModalForWindow:mainWindow];
}

- (void)genRevokeCertificateForKey:(GPGKey *)key {
	savePanel = [NSSavePanel savePanel];
	
	
	[savePanel setAllowsOtherFileTypes:YES];
	[savePanel setCanSelectHiddenExtension:YES];
	
	[savePanel setAllowedFileTypes:[NSArray arrayWithObjects:@"gpg", @"asc", @"pgp", nil]];
	
	NSString *filename = [NSString stringWithFormat:localized(@"%@ Revoke certificate"), [key shortKeyID]];
	
	NSDictionary *contextInfo = [[NSDictionary alloc] initWithObjectsAndKeys:key, @"key", [NSNumber numberWithInt:GKOpenSavePanelSaveRevokeCertificateAction], @"action", nil];
	
	[savePanel beginSheetForDirectory:nil file:filename modalForWindow:mainWindow modalDelegate:self didEndSelector:@selector(openSavePanelDidEnd:returnCode:contextInfo:) contextInfo:contextInfo];
	[NSApp runModalForWindow:mainWindow];
	
}


- (void)openSavePanelDidEnd:(NSOpenPanel *)sheet returnCode:(int)returnCode contextInfo:(NSDictionary *)contextInfo {
	[NSApp stopModal];
	if (returnCode == NSOKButton) {
		[sheet orderOut:self];
		switch ([[contextInfo objectForKey:@"action"] integerValue]) {
			case GKOpenSavePanelExportKeyAction: {
				NSSet *keys = [contextInfo objectForKey:@"keys"];
				BOOL hideExtension = [sheet isExtensionHidden];
				NSString *path = [[sheet URL] path];
				
				NSData *exportData = [actionController exportKeys:keys armored:(exportFormat & 1) allowSecret:allowSecretKeyExport fullExport:NO];
				if (exportData) {
					[[NSFileManager defaultManager] createFileAtPath:path contents:exportData attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:hideExtension] forKey:NSFileExtensionHidden]];
				} else {
					NSRunAlertPanel(localized(@"Error"), localized(@"Export failed!"), nil, nil, nil);
				}
				break; }
			case GKOpenSavePanelImportKeyAction:
				[actionController importFromURLs:[sheet URLs]];
				break;
			case GKOpenSavePanelAddPhotoAction: {
				GPGKey *key = [contextInfo objectForKey:@"key"];
				NSString *path = [[sheet URL] path];
				[actionController addPhotoForKey:key photoPath:path];
				break; }
			case GKOpenSavePanelSaveRevokeCertificateAction: {
				GPGKey *key = [contextInfo objectForKey:@"key"];
				BOOL hideExtension = [sheet isExtensionHidden];
				NSString *path = [[sheet URL] path];
				
				NSData *exportData = [actionController genRevokeCertificateForKey:key];
				if (exportData) {
					[[NSFileManager defaultManager] createFileAtPath:path contents:exportData attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:hideExtension] forKey:NSFileExtensionHidden]];
				} else {
					NSRunAlertPanel(localized(@"Error"), localized(@"Generate revoke certificate failed!"), nil, nil, nil);
				}
				break; }
		}
	}
}

- (NSInteger)alertSheetForWindow:(NSWindow *)window messageText:(NSString *)messageText infoText:(NSString *)infoText defaultButton:(NSString *)button1 alternateButton:(NSString *)button2 otherButton:(NSString *)button3 {
	NSAlert *alert = [[[NSAlert alloc] init] autorelease];
	[alert setMessageText:messageText];
	[alert setInformativeText:infoText];
	if (button1) {
		[alert addButtonWithTitle:button1];
	}
	if (button2) {
		[alert addButtonWithTitle:button2];
	}
	if (button2) {
		[alert addButtonWithTitle:button3];
	}
	
	[alert beginSheetModalForWindow:window modalDelegate:self didEndSelector:@selector(alertDidEnd:returnCode:contextInfo:) contextInfo:nil];
	[NSApp runModalForWindow:window];
	return lastReturnCode;
}

- (void)alertDidEnd:(NSAlert *)alert returnCode:(NSInteger)returnCode contextInfo:(void *)contextInfo {
	lastReturnCode = returnCode;
	[NSApp stopModal];
}

- (BOOL)panel:(NSOpenPanel *)sender validateURL:(NSURL *)url error:(NSError **)outError {
	NSString *path = [url path];
	unsigned long long filesize = [[[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] objectForKey:NSFileSize] unsignedLongLongValue];
	if (filesize > 1024 * 1024) { //Bilder über 1 MiB sind zu gross. (Meiner Meinung nach.)
		[self alertSheetForWindow:openPanel 
					  messageText:localized(@"This picture is to large!") 
						 infoText:localized(@"Please use a picature smaller than 1 MiB.") 
					defaultButton:nil 
				  alternateButton:nil 
					  otherButton:nil];
		return NO;
	} else if (filesize > 15 * 1024) { //Bei Bildern über 15 KiB nachfragen.
		NSInteger retVal =  [self alertSheetForWindow:openPanel 
										  messageText:localized(@"This picture is really large!") 
											 infoText:localized(@"You should use a smaller picture.") 
										defaultButton:localized(@"Choose another…") 
									  alternateButton:localized(@"Use this photo") 
										  otherButton:nil];
		if (retVal == NSAlertFirstButtonReturn) {
			return NO;
		}
	}
	return YES;
}




- (NSInteger)exportFormat {
	return exportFormat;
}
- (void)setExportFormat:(NSInteger)value {
	exportFormat = value;
	NSArray *extensions;
	switch (value) {
		case 1:
			extensions = [NSArray arrayWithObjects:@"asc", @"gpg", @"pgp", @"key", @"gpgkey", nil];
			break;
		default:
			extensions = [NSArray arrayWithObjects:@"gpg", @"asc", @"pgp", @"key", @"gpgkey", nil];
			break;
	}
	[savePanel setAllowedFileTypes:extensions];
}




@end


@implementation KeyLengthFormatter
@synthesize minKeyLength, maxKeyLength;

- (NSString*)stringForObjectValue:(id)obj {
	return [obj description];
}

- (NSInteger)checkedValue:(NSInteger)value {
	if (value < minKeyLength) {
		value = minKeyLength;
	}
	if (value > maxKeyLength) {
		value = maxKeyLength;
	}
	return value;
}

- (BOOL)getObjectValue:(id*)obj forString:(NSString*)string errorDescription:(NSString**)error {
	*obj = [NSString stringWithFormat:@"%i", [self checkedValue:[string integerValue]]];
	return YES;
}

- (BOOL)isPartialStringValid:(NSString*)partialString newEditingString:(NSString**) newString errorDescription:(NSString**)error {
	if ([partialString rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet] options: NSLiteralSearch].length == 0) {
		return YES;
	} else {
		return NO;
	}
}

@end


