//
//  UserRepository.swift
//  Habitica
//
//  Created by Phillip Thelen on 07.03.18.
//  Copyright © 2018 HabitRPG Inc. All rights reserved.
//

import Foundation
import Habitica_Models
import Habitica_Database
import Habitica_API_Client
import ReactiveSwift
import Crashlytics

class UserRepository: BaseRepository<UserLocalRepository> {
    
    var lastPushDeviceSync: Date?
    var lastClassSelection: Date?
    var taskRepository = TaskRepository()
    
    func retrieveUser(withTasks: Bool = true) -> Signal<UserProtocol?, Never> {
        let signal = RetrieveUserCall().objectSignal.on(value: { user in
            if let user = user {
                self.localRepository.save(user)
            }
        })
        if withTasks {
            let taskCall = RetrieveTasksCall()
            return signal.combineLatest(with: taskCall.arraySignal).on(value: { (user, tasks) in
                if let tasks = tasks, let order = user?.tasksOrder {
                    self.taskRepository.save(tasks, order: order)
                }
            }).map({ (user, _) in
                return user
            })
        } else {
            return signal
        }
    }
    
    func getUser() -> SignalProducer<UserProtocol, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest) {[weak self] (userID) in
            return self?.localRepository.getUser(userID) ?? SignalProducer.empty
        }
    }
    
    func allocate(attributePoint: String) -> Signal<StatsProtocol?, Never> {
        return AllocateAttributePointCall(attribute: attributePoint).objectSignal.on(value: {[weak self] stats in
            if let userId = self?.currentUserId, let stats = stats {
                self?.localRepository.save(userId, stats: stats)
            }
        })
    }
    
    func bulkAllocate(strength: Int, intelligence: Int, constitution: Int, perception: Int) -> Signal<StatsProtocol?, Never> {
        return BulkAllocateAttributePointsCall(strength: strength, intelligence: intelligence, constitution: constitution, perception: perception)
            .objectSignal.on(value: {[weak self] stats in
            if let userId = self?.currentUserId, let stats = stats {
                self?.localRepository.save(userId, stats: stats)
            }
        })
    }
    
    func hasUserData() -> Bool {
        if let userId = self.currentUserId {
            return localRepository.hasUserData(id: userId)
        } else {
            return false
        }
    }
    
    func useSkill(skill: SkillProtocol, targetId: String? = nil) -> Signal<SkillResponseProtocol?, Never> {
        return UseSkillCall(key: skill.key ?? "", target: skill.target ?? "", targetID: targetId).objectSignal.on(value: {[weak self] skillResponse in
                if let response = skillResponse {
                    self?.localRepository.save(userID: self?.currentUserId, skillResponse: response)
                }
            let toastView = ToastView(title: L10n.Skills.useSkill(skill.text ?? ""),
                                      rightIcon: HabiticaIcons.imageOfMagic,
                                      rightText: "-\(skill.mana)",
                rightTextColor: UIColor.blue10,
                background: .blue)
                ToastManager.show(toast: toastView)
                UINotificationFeedbackGenerator.oneShotNotificationOccurred(.success)
            })
    }
    
    func useTransformationItem(item: SpecialItemProtocol, targetId: String) -> Signal<EmptyResponseProtocol?, Never> {
        return UseTransformationItemCall(item: item, target: targetId).objectSignal.on(value: {[weak self] _ in
            self?.localRepository.usedTransformationItem(userID: self?.currentUserId ?? "", key: item.key ?? "")
            let toastView = ToastView(title: L10n.Skills.usedTransformationItem(item.text ?? ""), background: .gray)
            ToastManager.show(toast: toastView)
        })
    }
    
    func useDebuffItem(key: String) -> Signal<UserProtocol?, Never> {
        return UseSkillCall(key: key).objectSignal.flatMap(.latest) {[weak self] _ in
            return self?.retrieveUser() ?? Signal.empty
        }
    }
    
    func runCron(tasks: [TaskProtocol]) {
        var disposable: Disposable?
        getUser().take(first: 1).on(value: {[weak self]user in
            self?.localRepository.updateCall { _ in
                user.needsCron = false
            }
        }).start()
        if tasks.isEmpty == false {
            var signal = taskRepository.score(task: tasks[0], direction: .up)
            for task in tasks.dropFirst() {
                signal = signal.flatMap(.concat, {[weak self] _ in
                    return self?.taskRepository.score(task: task, direction: .up) ?? Signal.empty
                })
            }
            disposable = signal.flatMap(.latest, { _ in
                return RunCronCall().responseSignal
            }).flatMap(.latest, { _ in
                return self.retrieveUser()
            }).on(failed: { error in
                Crashlytics.sharedInstance().recordError(error)
            }).observeCompleted {
                disposable?.dispose()
            }
        } else {
            disposable = RunCronCall().responseSignal.flatMap(.latest, { (_) in
                return self.retrieveUser()
            }).on(failed: { error in
                Crashlytics.sharedInstance().recordError(error)
            }).observeCompleted {
                disposable?.dispose()
            }
        }
    }
    
    func updateUser(_ updateDict: [String: Encodable]) -> Signal<UserProtocol?, Never> {
        return UpdateUserCall(updateDict).objectSignal.on(value: handleUserUpdate())
    }
    
    func updateUser(key: String, value: Encodable) -> Signal<UserProtocol?, Never> {
        return updateUser([key: value])
    }
    
    func updateDayStartTime(_ time: Int) -> Signal<UserProtocol?, Never> {
        let call = UpdateDayStartTimeCall(time)
        
        return call.objectSignal.on(value: handleUserUpdate())
    }
    
    func sleep() -> Signal<EmptyResponseProtocol?, Never> {
        let call = SleepCall()
        
        return call.objectSignal.on(value: {[weak self]_ in
            if let userID = self?.currentUserId {
                self?.localRepository.toggleSleep(userID)
            }
        })
    }
    
    func login(username: String, password: String) -> Signal<LoginResponseProtocol?, Never> {
        let call = LocalLoginCall(username: username, password: password)
        
        return call.objectSignal.merge(with: call.responseSignal.map({ _ -> LoginResponseProtocol? in
            return nil
        }))
            .on(value: { loginResponse in
            if let response = loginResponse {
                AuthenticationManager.shared.currentUserId = response.id
                AuthenticationManager.shared.currentUserKey = response.apiToken
            }
        })
    }
    
    func register(username: String, password: String, confirmPassword: String, email: String) -> Signal<LoginResponseProtocol?, Never> {
        return LocalRegisterCall(username: username, password: password, confirmPassword: confirmPassword, email: email).objectSignal.on(value: { loginResponse in
            if let response = loginResponse {
                AuthenticationManager.shared.currentUserId = response.id
                AuthenticationManager.shared.currentUserKey = response.apiToken
            }
        })
    }
    
    func login(userID: String, network: String, accessToken: String) -> Signal<LoginResponseProtocol?, Never> {
        return SocialLoginCall(userID: userID, network: network, accessToken: accessToken).objectSignal.on(value: { loginResponse in
            if let response = loginResponse {
                AuthenticationManager.shared.currentUserId = response.id
                AuthenticationManager.shared.currentUserKey = response.apiToken
            }
        })
    }
    
    func loginApple(identityToken: String, name: String) -> Signal<LoginResponseProtocol?, Never> {
        return AppleLoginCall(identityToken: identityToken, name: name).objectSignal.on(value: { loginResponse in
            if let response = loginResponse {
                AuthenticationManager.shared.currentUserId = response.id
                AuthenticationManager.shared.currentUserKey = response.apiToken
            }
        })
    }
    
    func resetAccount() -> Signal<UserProtocol?, Never> {
        return ResetAccountCall().objectSignal.flatMap(.latest, {[weak self] (_) in
            return self?.retrieveUser() ?? Signal.empty
        })
    }
    
    func deleteAccount(password: String) -> Signal<HTTPURLResponse, Never> {
        return DeleteAccountCall(password: password).httpResponseSignal.on(value: {[weak self] response in
            if response.statusCode == 200 {
                self?.logoutAccount()
            }
        })
    }
    
    func logoutAccount() {
        localRepository.clearDatabase()
        if let userID = currentUserId {
            AuthenticationManager.shared.clearAuthentication(userId: userID)
        }
        deregisterPushDevice().observeCompleted {}
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys.forEach { defaults.removeObject(forKey: $0) }
    }
    
    func updateEmail(newEmail: String, password: String) -> Signal<UserProtocol, ReactiveSwiftRealmError> {
        let call = UpdateEmailCall(newEmail: newEmail, password: password)
        
        return call.objectSignal.flatMap(.concat, {[weak self] (_) in
            return self?.getUser().take(first: 1) ?? SignalProducer.empty
        }).on(value: {[weak self]user in
            self?.localRepository.updateCall { _ in
                if let local = user.authentication?.local {
                    local.email = newEmail
                }
            }
        })
    }
    
    func updateUsername(newUsername: String, password: String? = nil) -> Signal<UserProtocol, ReactiveSwiftRealmError> {
        let call = UpdateUsernameCall(username: newUsername, password: password)
        
        return call.objectSignal
            .filter({ (response) -> Bool in
                return response != nil
            })
            .flatMap(.concat, {[weak self] (_) in
            return self?.getUser().take(first: 1) ?? SignalProducer.empty
        }).on(value: {[weak self]user in
            self?.localRepository.updateCall { _ in
                if let local = user.authentication?.local {
                    local.username = newUsername
                    user.flags?.verifiedUsername = true
                }
            }
        })
    }
    
    func verifyUsername(_ newUsername: String) -> Signal<VerifyUsernameResponse?, Never> {
        let call = VerifyUsernameCall(username: newUsername)
        
        return call.objectSignal
    }
    
    func updatePassword(newPassword: String, password: String, confirmPassword: String) -> Signal<EmptyResponseProtocol?, Never> {
        let call = UpdatePasswordCall(newPassword: newPassword, oldPassword: password, confirmPassword: confirmPassword)
        
        return call.objectSignal
    }
    
    func revive() -> Signal<UserProtocol?, Never> {
        let call = ReviveUserCall()
        
        return call.objectSignal.flatMap(.latest, {[weak self] (_) in
            return self?.retrieveUser() ?? Signal.empty
        })
    }
    
    func getUserStyleWithOutfitFor(class habiticaClass: HabiticaClass, userID: String? = nil) -> SignalProducer<UserStyleProtocol, ReactiveSwiftRealmError> {
        return localRepository.getUserStyleWithOutfitFor(class: habiticaClass, userID: userID ?? currentUserId ?? "")
    }
    
    func getInAppRewards() -> SignalProducer<ReactiveResults<[InAppRewardProtocol]>, ReactiveSwiftRealmError> {
        return localRepository.getInAppRewards(userID: currentUserId ?? "")
    }
    
    func retrieveInAppRewards() -> Signal<[InAppRewardProtocol]?, Never> {
        let call = RetrieveInAppRewardsCall(language: LanguageHandler.getAppLanguage().code)
        
        return call.arraySignal.on(value: {[weak self] inAppRewards in
            if let userID = self?.currentUserId, let inAppRewards = inAppRewards {
                self?.localRepository.save(userID: userID, inAppRewards: inAppRewards)
            }
        })
    }
    
    func buyCustomReward(reward: TaskProtocol) -> Signal<TaskResponseProtocol?, Never> {
        return taskRepository.score(task: reward, direction: .down)
    }
    
    func disableClassSystem() -> Signal<UserProtocol?, Never> {
        if (lastClassSelection?.timeIntervalSinceNow ?? -31) > -30 {
            return Signal.empty
        }
        lastClassSelection = Date()
        return DisableClassesCall().objectSignal.on(value: handleUserUpdate())
    }
    
    func selectClass(_ habiticaClass: HabiticaClass? = nil) -> Signal<UserProtocol?, Never> {
        if (lastClassSelection?.timeIntervalSinceNow ?? -31) > -30 {
            return Signal.empty
        }
        lastClassSelection = Date()
        return SelectClassCall(class: habiticaClass).objectSignal.on(value: handleUserUpdate())
    }
    
    func reroll() -> Signal<UserProtocol?, Never> {
        return RerollCall().objectSignal.on(value: handleUserUpdate())
    }
    
    func sendPasswordResetEmail(email: String) -> Signal<EmptyResponseProtocol?, Never> {
        return SendPasswordResetEmailCall(email: email).objectSignal
    }
    
    func purchaseGems(receipt: [String: Any], recipient: String? = nil) -> Signal<EmptyResponseProtocol?, Never> {
        return PurchaseGemsCall(receipt: receipt, recipient: recipient).objectSignal
    }
    
    func sendGems(amount: Int, recipient: String) -> Signal<EmptyResponseProtocol?, Never> {
        return SendGemsCall(amount: amount, recipient: recipient).objectSignal
    }
    
    func purchaseNoRenewSubscription(identifier: String, receipt: [String: Any], recipient: String? = nil) -> Signal<EmptyResponseProtocol?, Never> {
        return PurchaseNoRenewSubscriptionCall(identifier: identifier, receipt: receipt, recipient: recipient).objectSignal
    }
    
    func subscribe(sku: String, receipt: String) -> Signal<EmptyResponseProtocol?, Never> {
        return SubscribeCall(sku: sku, receipt: receipt).objectSignal
    }
    
    func getTags() -> SignalProducer<ReactiveResults<[TagProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getTags(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func retrieveInboxMessages(conversationID: String, page: Int) -> Signal<[InboxMessageProtocol]?, Never> {
        let call = RetrieveInboxMessagesCall(uuid: conversationID, page: page)
        
        return call.arraySignal.on(value: {[weak self] messages in
            if let messages = messages, let userID = self?.currentUserId {
                self?.localRepository.save(userID: userID, messages: messages)
            }
        })
    }
    
    func retrieveInboxConversations() -> Signal<[InboxConversationProtocol]?, Never> {
        let call = RetrieveInboxConversationsCall()
        
        return call.arraySignal.on(value: {[weak self] conversations in
            if let conversations = conversations, let userID = self?.currentUserId {
                self?.localRepository.save(userID: userID, conversations: conversations)
            }
        })
    }
    
    func registerPushDevice(user: UserProtocol) -> Signal<EmptyResponseProtocol?, Never> {
        if (lastPushDeviceSync?.timeIntervalSinceNow ?? -31) > -30 {
            return Signal.empty
        }
        if let deviceID = UserDefaults().string(forKey: "PushNotificationDeviceToken") {
            if user.pushDevices.contains(where: { (pushDevice) -> Bool in
                return pushDevice.regId == deviceID
            }) != true {
                lastPushDeviceSync = Date()
                let call = RegisterPushDeviceCall(regID: deviceID)
                
                return call.objectSignal
            }
        }
        return Signal.empty
    }
    
    func deregisterPushDevice() -> Signal<EmptyResponseProtocol?, Never> {
        if let deviceID = UserDefaults().string(forKey: "PushNotificationDeviceToken") {
            let call = DeregisterPushDeviceCall(regID: deviceID)
            
            return call.objectSignal
        }
        return Signal.empty
    }
    
    func saveNotifications(_ notifications: [NotificationProtocol]?) {
        if let userID = currentUserId {
            localRepository.save(userID: userID, notifications: notifications)
        }
    }
    
    func getNotifications() -> SignalProducer<ReactiveResults<[NotificationProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getNotifications(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func getUnreadNotificationCount() -> SignalProducer<Int, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getUnreadNotificationCount(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func retrieveAchievements() -> Signal<[AchievementProtocol]?, Never> {
        return RetrieveAchievementsCall(userID: currentUserId ?? "").objectSignal.map({ achievementList in
            return achievementList?.achievements
        }).on(value: {[weak self] achievements in
            if let achievements = achievements {
                self?.localRepository.save(userID: self?.currentUserId ?? "", achievements: achievements)
            }
        })
    }
    
    func getAchievements() -> SignalProducer<ReactiveResults<[AchievementProtocol]>, ReactiveSwiftRealmError> {
        return currentUserIDProducer.skipNil().flatMap(.latest, {[weak self] (userID) in
            return self?.localRepository.getAchievements(userID: userID) ?? SignalProducer.empty
        })
    }
    
    func readNotification(notification: NotificationProtocol) -> Signal<[NotificationProtocol]?, Never> {
        if !notification.isValid {
            return Signal.empty
        }
        if notification.id.contains("-invite-") {
            localRepository.delete(object: notification)
            return Signal.empty
        } else {
            let call = ReadNotificationCall(notificationID: notification.id)
            
            return call.arraySignal.on(value: {[weak self] notifications in
                self?.saveNotifications(notifications)
            })
        }
    }
    
    func readNotifications(notifications: [NotificationProtocol]) -> Signal<[NotificationProtocol]?, Never> {
        let call = ReadNotificationsCall(notificationIDs: notifications.map({ $0.id }))
        
        return call.arraySignal.on(value: {[weak self] notifications in
            self?.saveNotifications(notifications)
        })
    }
    
    func createNotification(id: String, type: HabiticaNotificationType) -> NotificationProtocol {
        return localRepository.createNotification(userID: currentUserId ?? "", id: id, type: type)
    }
    
    private func handleUserUpdate() -> ((UserProtocol?) -> Void) {
        return {[weak self] updatedUser in
            if let userID = self?.currentUserId, let updatedUser = updatedUser {
                self?.localRepository.updateUser(id: userID, updateUser: updatedUser)
            }
        }
    }

}
